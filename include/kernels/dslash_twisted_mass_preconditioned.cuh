#include <kernels/dslash_wilson.cuh>
#include <linalg.cuh>

namespace quda {

  template <typename Float, int nColor, QudaReconstructType reconstruct_>
  struct TwistedMassArg : WilsonArg<Float,nColor,reconstruct_> {
    typedef typename mapper<Float>::type real;
    real a; // this is the scaling factor - separate from kappa since here we reserve kappa for xpay boolean
    real b; // this is the twist factor
    bool asymmetric; // whether we are applying the asymetric operator or not

    TwistedMassArg(ColorSpinorField &out, const ColorSpinorField &in, const GaugeField &U,
                   double a, double b, bool xpay, const ColorSpinorField &x,
                   int parity, bool dagger, bool asymmetric, const int *comm_override)
      : WilsonArg<Float,nColor,reconstruct_>(out, in, U, xpay ? 1.0 : 0.0, x, parity, dagger, comm_override),
      a(a), b(dagger ? -b : b), asymmetric(asymmetric) // if dagger flip the twist
    {
      if (dagger && !asymmetric) {
        DslashArg<Float>::twist_a = this->a;
        DslashArg<Float>::twist_b = this->b;
      }
    }
  };

  /**
     @brief Applies the off-diagonal part of the Wilson operator
     premultiplied by twist rotation - this is required for applying
     the symmetric preconditioned twisted-mass dagger operator.

     @param[out] out The out result field
     @param[in,out] arg Parameter struct
     @param[in] coord Site coordinate
     @param[in] x_cb The checker-boarded site index
     @param[in] parity Site parity
     @param[in] idx Thread index (equal to face index for exterior kernels)
     @param[in] thread_dim Which dimension this thread corresponds to (fused exterior only)
  */
  template <typename Float, int nDim, int nColor, int nParity, bool dagger, KernelType kernel_type, typename Arg, typename Vector>
  __device__ __host__ inline void applyWilsonTM(Vector &out, Arg &arg, int coord[nDim], int x_cb,
                                                int parity, int idx, int thread_dim, bool &active) {
    typedef typename mapper<Float>::type real;
    typedef ColorSpinor<real,nColor,2> HalfVector;
    typedef Matrix<complex<real>,nColor> Link;
    const int their_spinor_parity = nParity == 2 ? 1-parity : 0;

#pragma unroll
    for (int d = 0; d<nDim; d++) { // loop over dimension
      { // Forward gather - compute fwd offset for vector fetch
        const int fwd_idx = getNeighborIndexCB(coord, d, +1, arg.dc);
        constexpr int proj_dir = dagger ? +1 : -1;
        const bool ghost = (coord[d] + arg.nFace >= arg.dim[d]) &&
          isActive<kernel_type>(active, thread_dim, d, coord, arg);

        if ( doHalo<kernel_type>(d) && ghost ) {
          // we need to compute the face index if we are updating a face that isn't ours
          const int ghost_idx = (kernel_type == EXTERIOR_KERNEL_ALL && d != thread_dim) ?
            ghostFaceIndex<1>(coord, arg.dim, d, arg.nFace) : idx;

          Link U = arg.U(d, x_cb, parity);
          HalfVector in = arg.in.Ghost(d, 1, ghost_idx, their_spinor_parity);
          if (d == 3) in *= arg.t_proj_scale; // put this in the Ghost accessor and merge with any rescaling?

          out += (U * in).reconstruct(d, proj_dir);
        } else if ( doBulk<kernel_type>() && !ghost ) {

          Link U = arg.U(d, x_cb, parity);
          Vector in = arg.in(fwd_idx, their_spinor_parity);
          in = arg.a * (in + complex<real>(0.0,arg.b)*in.gamma(4)); // apply A^{-1} to in

          out += (U * in.project(d, proj_dir)).reconstruct(d, proj_dir);
        }
      }

      { // Backward gather - compute back offset for spinor and gauge fetch
        const int back_idx = getNeighborIndexCB(coord, d, -1, arg.dc);
        const int gauge_idx = back_idx;
        constexpr int proj_dir = dagger ? -1 : +1;
        const bool ghost = (coord[d] - arg.nFace < 0) &&
          isActive<kernel_type>(active, thread_dim, d, coord, arg);

        if ( doHalo<kernel_type>(d) && ghost) {
          // we need to compute the face index if we are updating a face that isn't ours
          const int ghost_idx = (kernel_type == EXTERIOR_KERNEL_ALL && d != thread_dim) ?
            ghostFaceIndex<0>(coord, arg.dim, d, arg.nFace) : idx;

          Link U = arg.U.Ghost(d, ghost_idx, 1-parity);
          HalfVector in = arg.in.Ghost(d, 0, ghost_idx, their_spinor_parity);
          if (d == 3) in *= arg.t_proj_scale;

          out += (conj(U) * in).reconstruct(d, proj_dir);
        } else if ( doBulk<kernel_type>() && !ghost ) {

          Link U = arg.U(d, gauge_idx, 1-parity);
          Vector in = arg.in(back_idx, their_spinor_parity);
          in = arg.a * (in + complex<real>(0.0,arg.b)*in.gamma(4)); // apply A^{-1} to in

          out += (conj(U) * in.project(d, proj_dir)).reconstruct(d, proj_dir);
        }
      }
    } //nDim

  }

  /**
     @brief Apply the preconditioned twisted-mass dslash
     - no xpay: out(x) = M*in = a*(1+i*b*gamma_5)D * in
     - with xpay:  out(x) = M*in = x + a*(1+i*b*gamma_5)D * in
  */
  template <typename Float, int nDim, int nColor, int nParity, bool dagger, bool asymmetric, bool xpay, KernelType kernel_type, typename Arg>
  __device__ __host__ inline void twistedMass(Arg &arg, int idx, int parity)
  {
    using namespace linalg; // for Cholesky
    typedef typename mapper<Float>::type real;
    typedef ColorSpinor<real,nColor,4> Vector;
    typedef ColorSpinor<real,nColor,2> HalfVector;

    bool active = kernel_type == EXTERIOR_KERNEL_ALL ? false : true; // is thread active (non-trival for fused kernel only)
    int thread_dim; // which dimension is thread working on (fused kernel only)
    int coord[nDim];
    int x_cb = getCoords<nDim,QUDA_4D_PC,kernel_type>(coord, arg, idx, parity, thread_dim);

    const int my_spinor_parity = nParity == 2 ? parity : 0;

    Vector out;

    if (dagger && !asymmetric)
      applyWilsonTM<Float,nDim,nColor,nParity,dagger,kernel_type>(out, arg, coord, x_cb, parity, idx, thread_dim, active);
    else // defined in dslash_wilson.cuh
      applyWilson<Float,nDim,nColor,nParity,dagger,kernel_type>(out, arg, coord, x_cb, parity, idx, thread_dim, active);

    if (kernel_type != INTERIOR_KERNEL && active) {
      // if we're not the interior kernel, then we must sum the partial
      Vector x = arg.out(x_cb, my_spinor_parity);
      out += x;
    }

    if ( isComplete<kernel_type>(arg, coord) && active ) {
      if (!dagger || asymmetric) out = arg.a * (out + complex<real>(0.0,arg.b)*out.gamma(4)); // apply A^{-1} to D*in
      if (xpay) {
	Vector x = arg.x(x_cb, my_spinor_parity);
	out += x;
      }
    }

    if (kernel_type != EXTERIOR_KERNEL_ALL || active) arg.out(x_cb, my_spinor_parity) = out;
  }

  // CPU kernel for applying the preconditioned twisted-mass operator to a vector
  template <typename Float, int nDim, int nColor, int nParity, bool dagger, bool asymmetric, bool xpay, KernelType kernel_type, typename Arg>
  void twistedMassCPU(Arg arg)
  {

    for (int parity= 0; parity < nParity; parity++) {
      // for full fields then set parity from loop else use arg setting
      parity = nParity == 2 ? parity : arg.parity;

      for (int x_cb = 0; x_cb < arg.threads; x_cb++) { // 4-d volume
        twistedMass<Float,nDim,nColor,nParity,dagger,asymmetric,xpay,kernel_type>(arg, x_cb, parity);
      } // 4-d volumeCB
    } // parity

  }

  // GPU Kernel for applying the preconditioned twisted-mass operator to a vector
  template <typename Float, int nDim, int nColor, int nParity, bool dagger, bool asymmetric, bool xpay, KernelType kernel_type, typename Arg>
  __global__ void twistedMassGPU(Arg arg)
  {
    int x_cb = blockIdx.x*blockDim.x + threadIdx.x;
    if (x_cb >= arg.threads) return;

    // for full fields set parity from y thread index else use arg setting
    int parity = nParity == 2 ? blockDim.z*blockIdx.z + threadIdx.z : arg.parity;

    switch(parity) {
    case 0: twistedMass<Float,nDim,nColor,nParity,dagger,asymmetric,xpay,kernel_type>(arg, x_cb, 0); break;
    case 1: twistedMass<Float,nDim,nColor,nParity,dagger,asymmetric,xpay,kernel_type>(arg, x_cb, 1); break;
    }

  }

} // namespace quda
