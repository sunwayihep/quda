#pragma once
#include <typeinfo>

#include <reduce_helper.h>
#include <uint_to_char.h>
#include <tune_quda.h>

/**
   @file transform_reduce.h

   @brief QUDA reimplementation of thrust::transform_reduce as well as
   wrappers also implementing thrust::reduce.
 */

namespace quda
{

  template <typename T> struct plus {
    __device__ __host__ T operator()(T a, T b) { return a + b; }
  };

  template <typename T> struct maximum {
    __device__ __host__ T operator()(T a, T b) { return a > b ? a : b; }
  };

  template <typename T> struct minimum {
    __device__ __host__ T operator()(T a, T b) { return a < b ? a : b; }
  };

  template <typename T> struct identity {
    __device__ __host__ T operator()(T a) { return a; }
  };

  template <typename reduce_t, typename T, typename count_t, typename transformer, typename reducer>
  struct TransformReduceArg : public ReduceArg<reduce_t> {
    static constexpr int block_size = 512;
    static constexpr int n_batch_max = 8;
    const T *v[n_batch_max];
    count_t n_items;
    int n_batch;
    reduce_t init;
    reduce_t result[n_batch_max];
    transformer h;
    reducer r;
    TransformReduceArg(const std::vector<T *> &v, count_t n_items, transformer h, reduce_t init, reducer r) :
      ReduceArg<reduce_t>(v.size()),
      n_items(n_items),
      n_batch(v.size()),
      init(init),
      h(h),
      r(r)
    {
      if (n_batch > n_batch_max) errorQuda("Requested batch %d greater than max supported %d", n_batch, n_batch_max);
      for (size_t j = 0; j < v.size(); j++) this->v[j] = v[j];
    }
  };

  template <typename Arg> void transform_reduce(Arg &arg)
  {
    using count_t = decltype(arg.n_items);
    using reduce_t = decltype(arg.init);

    for (int j = 0; j < arg.n_batch; j++) {
      auto v = arg.v[j];
      reduce_t r_ = arg.init;
      for (count_t i = 0; i < arg.n_items; i++) {
        auto v_ = arg.h(v[i]);
        r_ = arg.r(r_, v_);
      }
      arg.result[j] = r_;
    }
  }

  template <typename Arg> __launch_bounds__(Arg::block_size) __global__ void transform_reduce_kernel(Arg arg)
  {
    using count_t = decltype(arg.n_items);
    using reduce_t = decltype(arg.init);

    count_t i = blockIdx.x * blockDim.x + threadIdx.x;
    int j = blockIdx.y;
    auto v = arg.v[j];
    reduce_t r_ = arg.init;

    while (i < arg.n_items) {
      auto v_ = arg.h(v[i]);
      r_ = arg.r(r_, v_);
      i += blockDim.x * gridDim.x;
    }

    arg.template reduce<Arg::block_size, false, decltype(arg.r)>(r_, j);
  }

  template <typename reduce_t, typename T, typename I, typename transformer, typename reducer>
  class TransformReduce : Tunable
  {
    using Arg = TransformReduceArg<reduce_t, T, I, transformer, reducer>;
    QudaFieldLocation location;
    std::vector<reduce_t> &result;
    const std::vector<T *> &v;
    I n_items;
    transformer &h;
    reduce_t init;
    reducer &r;

    bool tuneSharedBytes() const { return false; }
    unsigned int sharedBytesPerThread() const { return 0; }
    unsigned int sharedBytesPerBlock(const TuneParam &param) const { return 0; }
    int blockMin() const { return Arg::block_size; }
    unsigned int maxBlockSize(const TuneParam &param) const { return Arg::block_size; }

    bool advanceTuneParam(TuneParam &param) const // only do autotuning if we have device fields
    {
      return location == QUDA_CUDA_FIELD_LOCATION ? Tunable::advanceTuneParam(param) : false;
    }

    void initTuneParam(TuneParam &param) const
    {
      Tunable::initTuneParam(param);
      param.grid.y = v.size();
    }

  public:
    TransformReduce(QudaFieldLocation location, std::vector<reduce_t> &result, const std::vector<T *> &v, I n_items,
                    transformer &h, reduce_t init, reducer &r) :
      location(location), result(result), v(v), n_items(n_items), h(h), init(init), r(r)
    {
      strcpy(aux, "batch_size=");
      u32toa(aux + 11, v.size());
      if (location == QUDA_CPU_FIELD_LOCATION) strcat(aux, ",cpu");
      apply(0);
    }

    void apply(const qudaStream_t &stream)
    {
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
      Arg arg(v, n_items, h, init, r);

      if (location == QUDA_CUDA_FIELD_LOCATION) {
        arg.launch_error = qudaLaunchKernel(transform_reduce_kernel<Arg>, tp, stream, arg);
        arg.complete(result, stream);
      } else {
        transform_reduce(arg);
        for (size_t j = 0; j < result.size(); j++) result[j] = arg.result[j];
      }
    }

    TuneKey tuneKey() const
    {
      char count[16];
      u32toa(count, n_items);
      return TuneKey(count, typeid(*this).name(), aux);
    }

    long long flops() const { return 0; } // just care about bandwidth
    long long bytes() const { return v.size() * n_items * sizeof(T); }
  };

  /**
     @brief QUDA implementation providing thrust::transform_reduce like
     functionality.  Improves upon thrust's implementation since a
     single kernel is used which writes the result directly to host
     memory, and is a batched implementation.
     @param[in] location Location where the reduction will take place
     @param[out] result Vector of results
     @param[in] v Vector of inputs
     @param[in] n_items Number of elements to be reduced in each input
     @param[in] transformer Functor that applies transform to each element
     @param[in] init The results are initialized to this value
     @param[in] reducer Functor that applies the reduction to each transformed element
   */
  template <typename reduce_t, typename T, typename I, typename transformer, typename reducer>
  void transform_reduce(QudaFieldLocation location, std::vector<reduce_t> &result, const std::vector<T *> &v, I n_items,
                        transformer h, reduce_t init, reducer r)
  {
    if (result.size() != v.size())
      errorQuda("result %lu and input %lu set sizes do not match", result.size(), v.size());
    TransformReduce<reduce_t, T, I, transformer, reducer> reduce(location, result, v, n_items, h, init, r);
  }

  /**
     @brief QUDA implementation providing thrust::transform_reduce like
     functionality.  Improves upon thrust's implementation since a
     single kernel is used which writes the result directly to host
     memory.
     @param[in] location Location where the reduction will take place
     @param[out] result Result
     @param[in] v Input vector
     @param[in] n_items Number of elements to be reduced
     @param[in] transformer Functor that applies transform to each element
     @param[in] init Results is initialized to this value
     @param[in] reducer Functor that applies the reduction to each transformed element
   */
  template <typename reduce_t, typename T, typename I, typename transformer, typename reducer>
  reduce_t transform_reduce(QudaFieldLocation location, const T *v, I n_items, transformer h, reduce_t init, reducer r)
  {
    std::vector<reduce_t> result = {0.0};
    std::vector<const T *> v_ = {v};
    transform_reduce(location, result, v_, n_items, h, init, r);
    return result[0];
  }

  /**
     @brief QUDA implementation providing thrust::reduce like
     functionality.  Improves upon thrust's implementation since a
     single kernel is used which writes the result directly to host
     memory, and is a batched implementation.
     @param[in] location Location where the reduction will take place
     @param[out] result Result
     @param[in] v Input vector
     @param[in] n_items Number of elements to be reduced
     @param[in] init The results are initialized to this value
     @param[in] reducer Functor that applies the reduction to each transformed element
   */
  template <typename reduce_t, typename T, typename I, typename transformer, typename reducer>
  void reduce(QudaFieldLocation location, std::vector<reduce_t> &result, const std::vector<T *> &v, I n_items,
              reduce_t init, reducer r)
  {
    transform_reduce(location, result, v, n_items, identity<T>(), init, r);
  }

  /**
     @brief QUDA implementation providing thrust::reduce like
     functionality.  Improves upon thrust's implementation since a
     single kernel is used which writes the result directly to host
     memory.
     @param[in] location Location where the reduction will take place
     @param[out] result Result
     @param[in] v Input vector
     @param[in] n_items Number of elements to be reduced
     @param[in] init Result is initialized to this value
     @param[in] reducer Functor that applies the reduction to each transformed element
   */
  template <typename reduce_t, typename T, typename I, typename reducer>
  reduce_t reduce(QudaFieldLocation location, const T *v, I n_items, reduce_t init, reducer r)
  {
    std::vector<reduce_t> result = {0.0};
    std::vector<const T *> v_ = {v};
    transform_reduce(location, result, v_, n_items, identity<T>(), init, r);
    return result[0];
  }
} // namespace quda
