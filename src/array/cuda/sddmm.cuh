/*!
 *  Copyright (c) 2020 by Contributors
 * \file array/cuda/sddmm.cuh
 * \brief SDDMM CUDA kernel function header.
 */
#ifndef DGL_ARRAY_CUDA_SDDMM_CUH_
#define DGL_ARRAY_CUDA_SDDMM_CUH_

#include <dgl/bcast.h>
#include "macro.cuh"
#include "atomic.cuh"
#include "functor.cuh"
#include "../../cuda_utils.h"
#include "../../runtime/cuda/cuda_common.h"

namespace dgl {

using namespace cuda;

namespace aten {
namespace cuda {

/*!
 * \brief CUDA kernel of g-SDDMM on Coo format.
 * \note it uses edge parallel strategy, different threadblocks (on y-axis)
 *       is responsible for the computation on different edges. Threadblocks
 *       on the x-axis are responsible for the computation on different positions
 *       in feature dimension.
 */
template <typename Idx, typename DType, typename BinaryOp,
          bool UseBcast = false, bool UseIdx = false>
__global__ void SDDMMCooKernel(
  const DType *ufeat, const DType *vfeat, DType *out,
  const Idx *row, const Idx *col, const Idx* edge_map,
  int64_t N, int64_t M, int64_t E, int64_t reduce_size,
  const int64_t *ubcast_off, const int64_t *vbcast_off,
  int64_t ufeat_len, int64_t vfeat_len, int64_t out_len) {
  // SDDMM with COO.
  Idx ty = blockIdx.y * blockDim.y + threadIdx.y;
  const Idx stride_y = blockDim.y * gridDim.y;
  while (ty < E) {
    const Idx src = _ldg(row + ty);
    const Idx dst = _ldg(col + ty);
    const Idx eid = UseIdx ? _ldg(edge_map + ty) : ty;
    const DType* lhsoff = BinaryOp::use_lhs ?
      (ufeat + src * ufeat_len): nullptr;
    const DType* rhsoff = BinaryOp::use_rhs ?
      (vfeat + dst * vfeat_len): nullptr;
    DType* outoff = out + eid * out_len;
    int tx = blockIdx.x * blockDim.x + threadIdx.x;
    const int stride_x = blockDim.x * gridDim.x;
    while (tx < out_len) {
      const Idx lhs_add = UseBcast ? ubcast_off[tx] : tx;
      const Idx rhs_add = UseBcast ? vbcast_off[tx] : tx;
      DType val = BinaryOp::Call(
          lhsoff + lhs_add * reduce_size,
          rhsoff + rhs_add * reduce_size,
          reduce_size);
      outoff[tx] = val;
      tx += stride_x;
    }
    ty += stride_y;
  }
}

// Binary search the row_offsets to find the source node of the edge id.
template <typename Idx>
__device__ __forceinline__ Idx BinarySearchSrc(const Idx *array, Idx length, Idx eid) {
  Idx lo = 0, hi = length - 1;
  while (lo < hi) {
    Idx mid = (lo + hi) >> 1;
    if (_ldg(array + mid) <= eid) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  // INVARIANT: lo == hi
  if (_ldg(array + hi) == eid) {
    return hi;
  } else {
    return hi - 1;
  }
}

/*!
 * \brief CUDA kernel of g-SDDMM on Csr format.
 * \note it uses edge parallel strategy, different threadblocks (on y-axis)
 *       is responsible for the computation on different edges. Threadblocks
 *       on the x-axis are responsible for the computation on different positions
 *       in feature dimension.
 *       To efficiently find the source node idx and destination node index of an 
 *       given edge on Csr format, it uses binary search (time complexity O(log N)).
 */
template <typename Idx, typename DType, typename BinaryOp,
          bool UseBcast = false, bool UseIdx = false>
__global__ void SDDMMCsrKernel(
  const DType *ufeat, const DType *vfeat, DType *out,
  const Idx *indptr, const Idx *indices, const Idx* edge_map,
  int64_t N, int64_t M, int64_t E, int64_t reduce_size,
  int64_t *ubcast_off, int64_t *vbcast_off,
  int64_t ufeat_len, int64_t vfeat_len, int64_t out_len) {
  // SDDMM with Csr.
  Idx ty = blockIdx.y * blockDim.y + threadIdx.y;
  const Idx stride_y = blockDim.y * gridDim.y;
  while (ty < E) {
    const Idx src = BinarySearchSrc<Idx>(indptr, N + 1, ty);
    const Idx dst = _ldg(indices + ty);
    const Idx eid = UseIdx ? _ldg(edge_map + ty) : ty;
    int64_t tx = blockIdx.x * blockDim.x + threadIdx.x;
    const int64_t stride_x = blockDim.x * gridDim.x;
    const DType* lhsoff = BinaryOp::use_lhs ? (ufeat + src * ufeat_len): nullptr;
    const DType* rhsoff = BinaryOp::use_rhs ? (vfeat + dst * vfeat_len): nullptr;
    DType* outoff = out + eid * out_len;
    while (tx < out_len) {
      const Idx lhs_add = UseBcast ? ubcast_off[tx] : tx;
      const Idx rhs_add = UseBcast ? vbcast_off[tx] : tx;
      DType val = BinaryOp::Call(
          lhsoff + lhs_add * reduce_size,
          rhsoff + rhs_add * reduce_size,
          reduce_size);
      outoff[tx] = val;
      tx += stride_x;
    }
    ty += stride_y;
  }
}

/*!
 * \brief CUDA implementation of g-SDDMM on Coo format.
 * \param bcast Broadcast information.
 * \param coo The Coo matrix.
 * \param ufeat The feature on source nodes.
 * \param vfeat The feature on destination nodes.
 * \param out The result feature on edges.
 */
template <typename Idx, typename DType, typename Op>
void SDDMMCoo(
    const BcastOff& bcast,
    const COOMatrix& coo,
    NDArray ufeat,
    NDArray vfeat,
    NDArray out) {
  const Idx *row = coo.row.Ptr<Idx>();
  const Idx *col = coo.col.Ptr<Idx>();
  const Idx *edge_map = coo.data.Ptr<Idx>();
  const DType *ufeat_data = ufeat.Ptr<DType>();
  const DType *vfeat_data = vfeat.Ptr<DType>();
  DType *out_data = out.Ptr<DType>();
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();

  int64_t *ubcast_off = nullptr, *vbcast_off = nullptr;
  int64_t len = bcast.out_len,
          lhs_len = bcast.lhs_len,
          rhs_len = bcast.rhs_len;
  int64_t reduce_dim = bcast.reduce_size;

  const int64_t nnz = coo.row->shape[0];
  const int ntx = FindNumThreads(len);
  const int nty = CUDA_MAX_NUM_THREADS / ntx;
  const int nbx = (len + ntx - 1) / ntx;
  const int nby = FindNumBlocks<'y'>((nnz + nty - 1) / nty);
  //LOG(INFO) << "nblks=(" << nbx << ", " << nby << ") nthrs=(" << ntx << ", " << nty << ")";
  const dim3 nblks(nbx, nby);
  const dim3 nthrs(ntx, nty);
  const bool use_idx = !IsNullArray(coo.data);

  BCAST_IDX_CTX_SWITCH(bcast, use_idx, ufeat->ctx, ubcast_off, vbcast_off, {
    SDDMMCooKernel<Idx, DType, Op, UseBcast, UseIdx>
      <<<nblks, nthrs, 0, thr_entry->stream>>>(
        ufeat_data, vfeat_data, out_data,
        row, col, edge_map,
        coo.num_rows, coo.num_cols, nnz, reduce_dim,
        ubcast_off, vbcast_off,
        lhs_len, rhs_len, len
      );
  });
}

/*!
 * \brief CUDA implementation of g-SDDMM on Csr format.
 * \param bcast Broadcast information.
 * \param csr The Csr matrix.
 * \param ufeat The feature on source nodes.
 * \param vfeat The feature on destination nodes.
 * \param out The result feature on edges.
 */
template <typename Idx, typename DType, typename Op>
void SDDMMCsr(
    const BcastOff& bcast,
    const CSRMatrix& csr,
    NDArray ufeat,
    NDArray vfeat,
    NDArray out) { const Idx *indptr = csr.indptr.Ptr<Idx>();
  const Idx *indices = csr.indices.Ptr<Idx>();
  const Idx *edge_map = csr.data.Ptr<Idx>();
  const DType *ufeat_data = ufeat.Ptr<DType>();
  const DType *vfeat_data = vfeat.Ptr<DType>();
  DType *out_data = out.Ptr<DType>();
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  int64_t N = csr.num_rows, M = csr.num_cols, E = csr.indices->shape[0];

  int64_t *ubcast_off = nullptr, *vbcast_off = nullptr;
  int64_t len = bcast.out_len,
          lhs_len = bcast.lhs_len,
          rhs_len = bcast.rhs_len;
  int64_t reduce_dim = bcast.reduce_size;

  const int ntx = FindNumThreads(len);
  const int nty = CUDA_MAX_NUM_THREADS / ntx;
  const int nbx = (len + ntx - 1) / ntx;
  const int nby = FindNumBlocks<'y'>((E + nty - 1) / nty);
  const dim3 nblks(nbx, nby);
  const dim3 nthrs(ntx, nty);
  const bool use_idx = !IsNullArray(csr.data);

  BCAST_IDX_CTX_SWITCH(bcast, use_idx, ufeat->ctx, ubcast_off, vbcast_off, {
    SDDMMCsrKernel<Idx, DType, Op, UseBcast, UseIdx>
      <<<nblks, nthrs, 0, thr_entry->stream>>>(
        ufeat_data, vfeat_data, out_data,
        indptr, indices, edge_map,
        N, M, E, reduce_dim,
        ubcast_off, vbcast_off,
        lhs_len, rhs_len, len
      );
  });
}

}  // namespace cuda
}  // namespace aten
}  // namespace dgl

#endif
