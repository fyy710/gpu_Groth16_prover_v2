#include <cstdint>
#include <vector>
#include <chrono>
#include <memory>
#include <cooperative_groups.h>

#include "curves.cu"

// C is the size of the precomputation
// R is the number of points we're handling per thread
template< typename EC, typename EC2, int C = 4, int RR = 8 >
__global__ void
ec_multiexp_straus(var *out, var *out1, var *out2, var *out3, 
                    const var *multiples_, const var *multiples1_, const var *multiples2_, const var *multiples3_,
                    const var *scalars_, size_t N)
{
    int T = threadIdx.x, B = blockIdx.x, D = blockDim.x;
    int elts_per_block = D / BIG_WIDTH;
    int tileIdx = T / BIG_WIDTH;

    int idx = elts_per_block * B + tileIdx;

    size_t n = (N + RR - 1) / RR;
    if (idx < n) {
        // TODO: Treat remainder separately so R can remain a compile time constant
        size_t R = (idx < n - 1) ? RR : (N % RR);

        typedef typename EC::group_type Fr;
        static constexpr int JAC_POINT_LIMBS = 3 * EC::field_type::DEGREE * ELT_LIMBS;
        static constexpr int AFF_POINT_LIMBS = 2 * EC::field_type::DEGREE * ELT_LIMBS;
        int out_off = idx * JAC_POINT_LIMBS;
        int m_off = idx * RR * AFF_POINT_LIMBS;
        int s_off = idx * RR * ELT_LIMBS;

        Fr scalars[RR];
        for (int j = 0; j < R; ++j) {
            Fr::load(scalars[j], scalars_ + s_off + j*ELT_LIMBS);
            Fr::from_monty(scalars[j], scalars[j]);
        }

        const var *multiples = multiples_ + m_off;
        const var *multiples1 = multiples1_ + m_off;
        const var *multiples2 = multiples2_ + m_off;
        // TODO: Consider loading multiples and/or scalars into shared memory

        // i is smallest multiple of C such that i > 753
        int CRound = C * ((753 + C - 1) / C); // C * ceiling(753/C)
        int i = CRound;
        assert((i - C * 753) < C);
        static constexpr var C_MASK = (1U << C) - 1U;

        int window[(C * ((753 + C - 1) / C))*RR + 1];

        EC x;
        EC::set_zero(x);
        int k = 0;
        while (i >= C) {
            EC::mul_2exp<C>(x, x);
            i -= C;

            int q = i / digit::BITS, r = i % digit::BITS;
            for (int j = 0; j < R; ++j) {
                //(scalars[j][q] >> r) & C_MASK
                auto g = fixnum::layout();
                var s = g.shfl(scalars[j].a, q);
                var win = (s >> r) & C_MASK;
                // Handle case where C doesn't divide digit::BITS
                int bottom_bits = digit::BITS - r;
                // detect when window overlaps digit boundary
                if (bottom_bits < C) {
                    s = g.shfl(scalars[j].a, q + 1);
                    win |= (s << bottom_bits) & C_MASK;
                }
                window[k*R+j] = win;
                if (win > 0) {
                    EC m;
                    EC::load_affine(m, multiples + ((win-1)*N + j)*AFF_POINT_LIMBS);
                    EC::mixed_add(x, x, m);
                }
            }
            k ++;
        }
        EC::store_jac(out + out_off, x);

        EC::set_zero(x);
        k = 0;
        i = CRound;
        while (i >= C) {
            EC::mul_2exp<C>(x, x);
            i -= C;

            for (int j = 0; j < R; ++j) {
                int win = window[k*R+j];
                if (win > 0) {
                    EC m;
                    EC::load_affine(m, multiples1 + ((win-1)*N + j)*AFF_POINT_LIMBS);
                    EC::mixed_add(x, x, m);
                }
            }
            k ++;
        }
        EC::store_jac(out1 + out_off, x);

        //if (idx >= 2)
        {
            EC::set_zero(x);
            k = 0;
            i = CRound;
            while (i >= C) {
                EC::mul_2exp<C>(x, x);
                i -= C;
                int j = 0;
                // TODO:
                if (idx == 0) {
                    j = 2;
                }

                for (; j < R; ++j) {
                    int win = window[k*R+j];
                    if (win > 0) {
                        EC m;
                        EC::load_affine(m, multiples2 + ((win-1)*(N-2) + j - 2)*AFF_POINT_LIMBS);
                        EC::mixed_add(x, x, m);
                    }
                }
                k ++;
            }
            EC::store_jac(out2 + out_off, x);
        }

        static constexpr int JAC_POINT_LIMBS_2 = 3 * EC2::field_type::DEGREE * ELT_LIMBS;
        static constexpr int AFF_POINT_LIMBS_2 = 2 * EC2::field_type::DEGREE * ELT_LIMBS;
        out_off = idx * JAC_POINT_LIMBS_2;
        m_off = idx * RR * AFF_POINT_LIMBS_2;
        const var *multiples3 = multiples3_ + m_off;

        EC2 y;
        EC2::set_zero(y);
        k = 0;
        i = CRound;
        while (i >= C) {
            EC2::mul_2exp<C>(y, y);
            i -= C;

            for (int j = 0; j < R; ++j) {
                int win = window[k*R+j];
                if (win > 0) {
                    EC2 m;
                    EC2::load_affine(m, multiples3 + ((win-1)*N + j)*AFF_POINT_LIMBS_2);
                    EC2::mixed_add(y, y, m);
                }
            }
            k ++;
        }
        EC2::store_jac(out3 + out_off, y);
    }
}

template< typename EC >
__global__ void
ec_multiexp(var *X, const var *W, size_t n)
{
    int T = threadIdx.x, B = blockIdx.x, D = blockDim.x;
    int elts_per_block = D / BIG_WIDTH;
    int tileIdx = T / BIG_WIDTH;

    int idx = elts_per_block * B + tileIdx;

    if (idx < n) {
        typedef typename EC::group_type Fr;
        EC x;
        Fr w;
        int x_off = idx * EC::NELTS * ELT_LIMBS;
        int w_off = idx * ELT_LIMBS;

        EC::load_affine(x, X + x_off);
        Fr::load(w, W + w_off);

        // We're given W in Monty form for some reason, so undo that.
        Fr::from_monty(w, w);
        EC::mul(x, w.a, x);

        EC::store_jac(X + x_off, x);
    }
}

template< typename EC >
__global__ void
ec_sum_all(var *X, const var *Y, size_t n)
{
    int T = threadIdx.x, B = blockIdx.x, D = blockDim.x;
    int elts_per_block = D / BIG_WIDTH;
    int tileIdx = T / BIG_WIDTH;

    int idx = elts_per_block * B + tileIdx;

    if (idx < n) {
        EC z, x, y;
        int off = idx * EC::NELTS * ELT_LIMBS;

        EC::load_jac(x, X + off);
        EC::load_jac(y, Y + off);

        EC::add(z, x, y);

        EC::store_jac(X + off, z);
    }
}

static constexpr size_t threads_per_block = 512;
template< typename EC, typename EC2, int C, int R >
void
ec_reduce_straus(var *out, var *out1, var *out2, var *out3,
                    const var *multiples, const var *multiples1, const var *multiples2, const var *multiples3,
                    const var *scalars, size_t N)
{
    static constexpr size_t pt_limbs = EC::NELTS * ELT_LIMBS;
    static constexpr size_t pt2_limbs = EC2::NELTS * ELT_LIMBS;
    size_t n = (N + R - 1) / R;

    size_t nblocks = (n * BIG_WIDTH + threads_per_block - 1) / threads_per_block;
    printf("nblocks %d\n", nblocks);

    ec_multiexp_straus<EC, EC2, C, R><<< nblocks, threads_per_block>>>(out, out1, out2, out3, multiples, multiples1, multiples2, multiples3, scalars, N);

    size_t r = n & 1, m = n / 2;
    for ( ; m != 0; r = m & 1, m >>= 1) {
        nblocks = (m * BIG_WIDTH + threads_per_block - 1) / threads_per_block;

        ec_sum_all<EC><<<nblocks, threads_per_block>>>(out, out + m*pt_limbs, m);
        if (r)
            ec_sum_all<EC><<<1, threads_per_block>>>(out, out + 2*m*pt_limbs, 1);
    }
    r = n & 1, m = n / 2;
    for ( ; m != 0; r = m & 1, m >>= 1) {
        nblocks = (m * BIG_WIDTH + threads_per_block - 1) / threads_per_block;

        ec_sum_all<EC><<<nblocks, threads_per_block>>>(out1, out1 + m*pt_limbs, m);
        if (r)
            ec_sum_all<EC><<<1, threads_per_block>>>(out1, out1 + 2*m*pt_limbs, 1);
    }
    r = n & 1, m = n / 2;
    for ( ; m != 0; r = m & 1, m >>= 1) {
        nblocks = (m * BIG_WIDTH + threads_per_block - 1) / threads_per_block;

        ec_sum_all<EC2><<<nblocks, threads_per_block>>>(out3, out3 + m*pt2_limbs, m);
        if (r)
            ec_sum_all<EC2><<<1, threads_per_block>>>(out3, out3 + 2*m*pt2_limbs, 1);
    }
    //n = (N - 2 + R - 1) / R;
    r = n & 1, m = n / 2;
    for ( ; m != 0; r = m & 1, m >>= 1) {
        nblocks = (m * BIG_WIDTH + threads_per_block - 1) / threads_per_block;

        ec_sum_all<EC><<<nblocks, threads_per_block>>>(out2, out2 + m*pt_limbs, m);
        if (r)
            ec_sum_all<EC><<<1, threads_per_block>>>(out2, out2 + 2*m*pt_limbs, 1);
    }
}

template< typename EC >
void
ec_reduce(cudaStream_t &strm, var *X, const var *w, size_t n)
{
    cudaStreamCreate(&strm);

    size_t nblocks = (n * BIG_WIDTH + threads_per_block - 1) / threads_per_block;

    // FIXME: Only works on Pascal and later.
    //auto grid = cg::this_grid();
    ec_multiexp<EC><<< nblocks, threads_per_block, 0, strm>>>(X, w, n);

    static constexpr size_t pt_limbs = EC::NELTS * ELT_LIMBS;

    size_t r = n & 1, m = n / 2;
    for ( ; m != 0; r = m & 1, m >>= 1) {
        nblocks = (m * BIG_WIDTH + threads_per_block - 1) / threads_per_block;

        ec_sum_all<EC><<<nblocks, threads_per_block, 0, strm>>>(X, X + m*pt_limbs, m);
        if (r)
            ec_sum_all<EC><<<1, threads_per_block, 0, strm>>>(X, X + 2*m*pt_limbs, 1);
        // TODO: Not sure this is really necessary.
        //grid.sync();
    }
}

static inline double as_mebibytes(size_t n) {
    return n / (long double)(1UL << 20);
}

void print_meminfo(size_t allocated) {
    size_t free_mem, dev_mem;
    cudaMemGetInfo(&free_mem, &dev_mem);
    fprintf(stderr, "Allocated %zu bytes; device has %.1f MiB free (%.1f%%).\n",
            allocated,
            as_mebibytes(free_mem),
            100.0 * free_mem / dev_mem);
}

struct CudaFree {
    void operator()(var *mem) { cudaFree(mem); }
};
typedef std::unique_ptr<var, CudaFree> var_ptr;

var_ptr
allocate_memory(size_t nbytes, int dbg = 0) {
    var *mem = nullptr;
    cudaMallocManaged(&mem, nbytes);
    if (mem == nullptr) {
        fprintf(stderr, "Failed to allocate enough device memory\n");
        abort();
    }
    if (dbg)
        print_meminfo(nbytes);
    return var_ptr(mem);
}

var_ptr
load_scalars(size_t n, FILE *inputs)
{
    static constexpr size_t scalar_bytes = ELT_BYTES;
    size_t total_bytes = n * scalar_bytes;

    auto mem = allocate_memory(total_bytes);
    if (fread((void *)mem.get(), total_bytes, 1, inputs) < 1) {
        fprintf(stderr, "Failed to read scalars\n");
        abort();
    }
    return mem;
}

template< typename EC >
var_ptr
load_points(size_t n, FILE *inputs)
{
    typedef typename EC::field_type FF;

    static constexpr size_t coord_bytes = FF::DEGREE * ELT_BYTES;
    static constexpr size_t aff_pt_bytes = 2 * coord_bytes;
    static constexpr size_t jac_pt_bytes = 3 * coord_bytes;

    size_t total_aff_bytes = n * aff_pt_bytes;
    size_t total_jac_bytes = n * jac_pt_bytes;

    auto mem = allocate_memory(total_jac_bytes);
    if (fread((void *)mem.get(), total_aff_bytes, 1, inputs) < 1) {
        fprintf(stderr, "Failed to read all curve poinst\n");
        abort();
    }

    // insert space for z-coordinates
    char *cmem = reinterpret_cast<char *>(mem.get()); //lazy
    for (size_t i = n - 1; i > 0; --i) {
        char tmp_pt[aff_pt_bytes];
        memcpy(tmp_pt, cmem + i * aff_pt_bytes, aff_pt_bytes);
        memcpy(cmem + i * jac_pt_bytes, tmp_pt, aff_pt_bytes);
    }
    return mem;
}

template< typename EC >
var_ptr
load_points_affine(size_t n, FILE *inputs)
{
    typedef typename EC::field_type FF;

    static constexpr size_t coord_bytes = FF::DEGREE * ELT_BYTES;
    static constexpr size_t aff_pt_bytes = 2 * coord_bytes;

    size_t total_aff_bytes = n * aff_pt_bytes;

    auto mem = allocate_memory(total_aff_bytes);
    if (fread((void *)mem.get(), total_aff_bytes, 1, inputs) < 1) {
        fprintf(stderr, "Failed to read all curve poinst\n");
        abort();
    }
    return mem;
}
