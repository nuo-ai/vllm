#include <c10/core/ScalarType.h>
#include <torch/all.h>
#include <ATen/cuda/CUDAContext.h>
#include "permute_unpermute_kernels/moe_permute_unpermute_kernel.h"
#include "permute_unpermute_kernels/dispatch.h"
#include "core/registration.h"

// moe_permute kernels require at least CUDA 12.0
#if defined(CUDA_VERSION) && (CUDA_VERSION >= 12000)

void moe_permute(
    const torch::Tensor& input,                      // [n_token, hidden]
    const torch::Tensor& topk_ids,                   // [n_token, topk]
    const torch::Tensor& token_expert_indices,       // [n_token, topk]
    const std::optional<torch::Tensor>& expert_map,  // [n_expert]
    int64_t n_expert, int64_t n_local_expert, int64_t topk,
    const std::optional<int64_t>& align_block_size,
    torch::Tensor& permuted_input,             // [permuted_size, hidden]
    torch::Tensor& expert_first_token_offset,  // [n_local_expert + 1]
    torch::Tensor& inv_permuted_idx,           // [n_token, topk]
    torch::Tensor& permuted_idx,               // [permute_size]
    torch::Tensor& m_indices) {                // [align_expand_m]
  TORCH_CHECK(expert_first_token_offset.scalar_type() == at::ScalarType::Long,
              "expert_first_token_offset must be int64");
  TORCH_CHECK(topk_ids.scalar_type() == at::ScalarType::Int,
              "topk_ids must be int32");
  TORCH_CHECK(token_expert_indices.scalar_type() == at::ScalarType::Int,
              "token_expert_indices must be int32");
  TORCH_CHECK(inv_permuted_idx.scalar_type() == at::ScalarType::Int,
              "inv_permuted_idx must be int32");
  TORCH_CHECK(expert_first_token_offset.size(0) == n_local_expert + 1,
              "expert_first_token_offset shape != n_local_expert+1")
  TORCH_CHECK(inv_permuted_idx.sizes() == token_expert_indices.sizes(),
              "token_expert_indices shape must be same as inv_permuted_idx");
  auto n_token = input.sizes()[0];
  auto n_hidden = input.sizes()[1];
  auto align_block_size_value =
      align_block_size.has_value() ? align_block_size.value() : -1;
  auto stream = at::cuda::getCurrentCUDAStream().stream();
  const long sorter_size =
      CubKeyValueSorter::getWorkspaceSize(n_token * topk, n_expert);
  auto sort_workspace = torch::empty(
      {sorter_size},
      torch::dtype(torch::kInt8).device(torch::kCUDA).requires_grad(false));
  auto copy_topk_ids = topk_ids.clone();  // copy topk_ids for preprocess
  auto permuted_experts_id = torch::empty_like(topk_ids);
  auto sorted_row_idx = torch::empty_like(inv_permuted_idx);
  auto align_expert_first_token_offset =
      torch::zeros_like(expert_first_token_offset);

  CubKeyValueSorter sorter{};
  int64_t* valid_num_ptr = nullptr;
  // pre-process kernel for expert-parallelism:
  // no local expert id plus "n_expert" offset for priority to local expert
  // map local expert id [n, .., n+n_local_expert-1] to [0, n_local_expert -1]
  // For example, 4 expert with ep_size=2. ep_rank=1 owns global expert id
  // [2,3] with expert_map[-1, -1, 0, 1], preprocess_topk_id  process topk_ids
  // and map global expert id [2, 3] to local_expert id [0, 1] and map global
  // expert id [0, 1] ( not in ep rank=1)  to [4, 5] by plus n_expert. This map
  // operation is to make local expert high priority in following sort topk_ids
  // and scan local expert_first_token_offset for each ep rank for next group
  // gemm.
  if (expert_map.has_value()) {
    const int* expert_map_ptr = get_ptr<int>(expert_map.value());
    valid_num_ptr =
        get_ptr<int64_t>(expert_first_token_offset) + n_local_expert;
    preprocessTopkIdLauncher(get_ptr<int>(copy_topk_ids), n_token * topk,
                             expert_map_ptr, n_expert, stream);
  }
  // expert sort topk expert id and scan expert id get expert_first_token_offset
  sortAndScanExpert(
      get_ptr<int>(copy_topk_ids), get_ptr<int>(token_expert_indices),
      get_ptr<int>(permuted_experts_id), get_ptr<int>(sorted_row_idx),
      get_ptr<int64_t>(expert_first_token_offset), n_token, n_expert,
      n_local_expert, topk, sorter, get_ptr<int>(sort_workspace), stream);

  // dispatch expandInputRowsKernelLauncher
  MOE_DISPATCH(input.scalar_type(), [&] {
    expandInputRowsKernelLauncher<scalar_t>(
        get_ptr<scalar_t>(input), get_ptr<scalar_t>(permuted_input),
        get_ptr<int>(permuted_experts_id), get_ptr<int>(sorted_row_idx),
        get_ptr<int>(inv_permuted_idx), get_ptr<int>(permuted_idx),
        get_ptr<int64_t>(expert_first_token_offset), n_token, valid_num_ptr,
        n_hidden, topk, n_local_expert, align_block_size_value, stream);
  });

  // get m_indices and update expert_first_token_offset with align block
  getMIndices(get_ptr<int64_t>(expert_first_token_offset),
              get_ptr<int64_t>(align_expert_first_token_offset),
              get_ptr<int>(m_indices), n_local_expert, align_block_size_value,
              stream);
  if (align_block_size.has_value()) {
    // update align_expert_first_token_offset
    expert_first_token_offset.copy_(align_expert_first_token_offset);
  }
}

void moe_unpermute(
    const torch::Tensor& permuted_hidden_states,  // [n_token * topk, hidden]
    const torch::Tensor& topk_weights,            // [n_token, topk]
    const torch::Tensor& inv_permuted_idx,        // [n_token, topk]
    const std::optional<torch::Tensor>&
        expert_first_token_offset,  // [n_local_expert+1]
    int64_t topk,
    torch::Tensor& hidden_states  // [n_token, hidden]
) {
  TORCH_CHECK(
      permuted_hidden_states.scalar_type() == hidden_states.scalar_type(),
      "permuted_hidden_states dtype must be same as hidden_states");
  auto n_token = hidden_states.size(0);
  auto n_hidden = hidden_states.size(1);
  auto stream = at::cuda::getCurrentCUDAStream().stream();

  int64_t const* valid_ptr = nullptr;
  if (expert_first_token_offset.has_value()) {
    int n_local_expert = expert_first_token_offset.value().size(0) - 1;
    valid_ptr =
        get_ptr<int64_t>(expert_first_token_offset.value()) + n_local_expert;
  }

  MOE_DISPATCH(hidden_states.scalar_type(), [&] {
    finalizeMoeRoutingKernelLauncher<scalar_t, scalar_t>(
        get_ptr<scalar_t>(permuted_hidden_states),
        get_ptr<scalar_t>(hidden_states), get_ptr<float>(topk_weights),
        get_ptr<int>(inv_permuted_idx), n_token, n_hidden, topk, valid_ptr,
        stream);
  });
}

template <typename T>
__global__ void shuffleInputRowsKernel(const T* input,
                                       const int32_t* dst2src_map, T* output,
                                       int64_t num_src_rows,
                                       int64_t num_dst_rows, int64_t num_cols) {
  int64_t dest_row_idx = blockIdx.x;
  int64_t const source_row_idx = dst2src_map[dest_row_idx];

  if (blockIdx.x < num_dst_rows) {
    // Load 128-bits per thread
    constexpr int64_t ELEM_PER_THREAD = 128 / sizeof(T) / 8;
    using DataElem = cutlass::Array<T, ELEM_PER_THREAD>;

    // Duplicate and permute rows
    auto const* source_row_ptr =
        reinterpret_cast<DataElem const*>(input + source_row_idx * num_cols);
    auto* dest_row_ptr =
        reinterpret_cast<DataElem*>(output + dest_row_idx * num_cols);

    int64_t const start_offset = threadIdx.x;
    int64_t const stride = blockDim.x;
    int64_t const num_elems_in_col = num_cols / ELEM_PER_THREAD;

    for (int elem_index = start_offset; elem_index < num_elems_in_col;
         elem_index += stride) {
      dest_row_ptr[elem_index] = source_row_ptr[elem_index];
    }
  }
}

void shuffle_rows(const torch::Tensor& input_tensor,
                  const torch::Tensor& dst2src_map,
                  torch::Tensor& output_tensor) {
  TORCH_CHECK(input_tensor.scalar_type() == output_tensor.scalar_type(),
              "Input and output tensors must have the same data type");

  auto stream = at::cuda::getCurrentCUDAStream().stream();
  int64_t const blocks = output_tensor.size(0);
  int64_t const threads = 256;
  int64_t const num_dest_rows = output_tensor.size(0);
  int64_t const num_src_rows = input_tensor.size(0);
  int64_t const num_cols = input_tensor.size(1);

  TORCH_CHECK(!(num_cols % (128 / sizeof(input_tensor.scalar_type()) / 8)),
              "num_cols must be divisible by 128 / "
              "sizeof(input_tensor.scalar_type()) / 8");

  MOE_DISPATCH(input_tensor.scalar_type(), [&] {
    shuffleInputRowsKernel<scalar_t><<<blocks, threads, 0, stream>>>(
        reinterpret_cast<scalar_t*>(input_tensor.data_ptr()),
        dst2src_map.data_ptr<int32_t>(),
        reinterpret_cast<scalar_t*>(output_tensor.data_ptr()), num_src_rows,
        num_dest_rows, num_cols);
  });
}

#else

void moe_permute(const torch::Tensor& input, const torch::Tensor& topk_weights,
                 torch::Tensor& topk_ids,
                 const torch::Tensor& token_expert_indices,
                 const std::optional<torch::Tensor>& expert_map,
                 int64_t n_expert, int64_t n_local_expert, int64_t topk,
                 const std::optional<int64_t>& align_block_size,
                 torch::Tensor& permuted_input,
                 torch::Tensor& expert_first_token_offset,
                 torch::Tensor& src_row_id2dst_row_id_map,
                 torch::Tensor& m_indices) {
  TORCH_CHECK(false, "moe_unpermute is not supported on CUDA < 12.0");
}

void moe_unpermute(const torch::Tensor& input,
                   const torch::Tensor& topk_weights, torch::Tensor& topk_ids,
                   const torch::Tensor& token_expert_indices,
                   const std::optional<torch::Tensor>& expert_map,
                   int64_t n_expert, int64_t n_local_expert, int64_t topk,
                   const std::optional<int64_t>& align_block_size,
                   torch::Tensor& permuted_input,
                   torch::Tensor& expert_first_token_offset,
                   torch::Tensor& src_row_id2dst_row_id_map,
                   torch::Tensor& m_indices) {
  TORCH_CHECK(false, "moe_unpermute is not supported on CUDA < 12.0");
}

#endif

bool moe_permute_unpermute_supported() {
#if defined(CUDA_VERSION) && (CUDA_VERSION >= 12000)
  return true;
#else
  return false;
#endif
}

TORCH_LIBRARY_IMPL_EXPAND(TORCH_EXTENSION_NAME, CUDA, m) {
  m.impl("moe_permute", &moe_permute);
  m.impl("moe_unpermute", &moe_unpermute);
}
