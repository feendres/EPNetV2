#include <torch/extension.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <myGridSampler.cuh>
#include <vector>
#include <stdio.h>

//using namespace std;
namespace{

template <typename scalar_t>
__global__ void voxel_2d_kernel(
          const at::PackedTensorAccessor64<scalar_t,3,at::RestrictPtrTraits> input,
          const at::PackedTensorAccessor64<scalar_t,3,at::RestrictPtrTraits> grid,
           at::PackedTensorAccessor64<scalar_t,4,at::RestrictPtrTraits> output,
           at::PackedTensorAccessor64<int,3,at::RestrictPtrTraits> output_count)
{
    // input (N,C,H)
    // grid (N,H,Coor)
    // output (N,C, H, W)
    // output_count (N,H,W)
    int C = input.size(1);
    int input_H=input.size(2);

    int out_H = output.size(2);
    int out_W = output.size(3);

    int grid_H=grid.size(1);
    int grid_Coor=grid.size(2);

        //batch index
      const int n = blockIdx.y;
      // column index
      const int h = blockIdx.x * blockDim.x + threadIdx.x;
      if(h < input_H){
        // get the corresponding input x, y co-ordinates from grid
      scalar_t ix = grid[n][h][0];
      scalar_t iy = grid[n][h][1];

      ix = grid_sampler_compute_source_index(ix, out_W);
      iy = grid_sampler_compute_source_index(iy, out_H);

        int ix_nearest = static_cast<int>(::round(ix));
        int iy_nearest = static_cast<int>(::round(iy));

        // assign nearest neighor pixel value to output pixel
        if (within_bounds_2d(iy_nearest, ix_nearest, out_H, out_W)) {
            atomicAdd((int* )&(output_count[n][iy_nearest][ix_nearest]), int(1));
//            safe_add_2d(count_ptr, iy_nearest, ix_nearest, out_ct_sH, out_ct_sW, out_H, out_W, 1);
            for (int c = 0; c < C; ++c) {
              // calculate and set grad_input
              atomicAdd((scalar_t* )&(output[n][c][iy_nearest][ix_nearest]),input[n][c][h]);
            }
        }
      }
}

template <typename scalar_t>
__global__ void voxel_2d_normal_kernel(
           at::PackedTensorAccessor64<scalar_t,4,at::RestrictPtrTraits> output,
           const at::PackedTensorAccessor64<int,3,at::RestrictPtrTraits> output_count)
{
    // output (N,C, H, W)
    // output_count (N,H,W)
    int C = output.size(1);
    int out_H = output.size(2);
    int out_W = output.size(3);


        //batch index
      const int n = blockIdx.y;
      // column index
      const int hw = blockIdx.x * blockDim.x + threadIdx.x;
      const int h=hw/out_W;
      const int w=hw -h*out_W;
      if(h < out_H &&w < out_W){
        // get the corresponding input x, y coordinates from grid
        // assign nearest neighbor pixel value to output pixel
        int ct=output_count[n][h][w];
        if(ct>0){
            for (int c=0;c<C;c++){
                output[n][c][h][w]/=ct;
            }
        }
      }
}

template <typename scalar_t>
__global__ void voxel_2d_backward_kernel(
  const at::PackedTensorAccessor64<scalar_t,3,at::RestrictPtrTraits> grid,
  const at::PackedTensorAccessor64<int,3,at::RestrictPtrTraits> output_count,
  const at::PackedTensorAccessor64<scalar_t,4,at::RestrictPtrTraits> grad_output,
  at::PackedTensorAccessor64<scalar_t,3,at::RestrictPtrTraits> grad_input)
{

    // grid (N,H,Coor)
    // output_count (N, H, W)
    // grad_output (N,C,H,W)
    // grad_input (N,C,H2)

    int C = grad_output.size(1);
    int gInp_H = grad_input.size(2);

    int grid_H = grid.size(1);

    int out_H=output_count.size(1);
    int out_W=output_count.size(2);

        //batch index
      const int n = blockIdx.y;
      // column index
      const int h = blockIdx.x * blockDim.x + threadIdx.x;
      if(h < gInp_H){
            // get the corresponding input x, y co-ordinates from grid
          scalar_t ix = grid[n][h][0];
          scalar_t iy = grid[n][h][1];

          ix = grid_sampler_compute_source_index(ix, out_W);
          iy = grid_sampler_compute_source_index(iy, out_H);


            int ix_nearest = static_cast<int>(::round(ix));
            int iy_nearest = static_cast<int>(::round(iy));

            // assign nearest neighor pixel value to output pixel
            auto ct= output_count[n][iy_nearest][ix_nearest];
            if(ct<=0 || !within_bounds_2d(iy_nearest, ix_nearest, out_H, out_W)){
                //TODO check here
                for (int c = 0; c < C; ++c) {
                    grad_input[n][c][h] = static_cast<scalar_t>(0);
                }
            }else{
                for (int c = 0; c < C; ++c) {
//                    printf('%f',static_cast<float>(grad_output[n][c][iy_nearest][ix_nearest]/ct));
                    grad_input[n][c][h] = grad_output[n][c][iy_nearest][ix_nearest]/(float)ct;
                }
            }
      }

}

}//namespace

// No shape checking needed here. See # NOTE [ grid_sampler Native Functions ].
std::tuple<torch::Tensor, torch::Tensor>
grid_voxel_2d_cuda_forward(const torch::Tensor& input, const torch::Tensor& grid, torch::Tensor& output, torch::Tensor& output_count) {
  const auto N = grid.size(0);
  const auto H = grid.size(1);

  const int threads=1024;
  const dim3 blocks((H+threads-1)/threads, N);

//    AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "grid_voxel_2d_cuda", ([&] {
      voxel_2d_kernel<float>
        <<<blocks,threads>>>(
          input.packed_accessor64<float,3,torch::RestrictPtrTraits>(),
          grid.packed_accessor64<float,3,torch::RestrictPtrTraits>(),
          output.packed_accessor64<float,4,torch::RestrictPtrTraits>(),
          output_count.packed_accessor64<int,3,torch::RestrictPtrTraits>());
//    }));
         const auto out_H=output.size(2);
         const auto out_W=output.size(3);
        dim3 blocks2((out_H*out_W+threads-1)/threads, N);

       voxel_2d_normal_kernel<float>
       <<<blocks2,threads>>>(
          output.packed_accessor64<float,4,torch::RestrictPtrTraits>(),
          output_count.packed_accessor64<int,3,torch::RestrictPtrTraits>()
       );

  return std::make_tuple(output,output_count);
};

// No shape checking needed here. See # NOTE [ grid_sampler Native Functions ].
torch::Tensor grid_voxel_2d_cuda_backward(const torch::Tensor& grid, const torch::Tensor& output_count,
                            const torch::Tensor& grad_output,torch::Tensor& grad_input) {
  const auto N = grid.size(0);
  const auto H = grid.size(1);

  const int threads=1024;
  const dim3 blocks((H+threads-1)/threads, N);


//    AT_DISPATCH_FLOATING_TYPES(output_count.scalar_type(), "grid_voxel_2d_backward_cuda", ([&] {
      voxel_2d_backward_kernel<float>
        <<<blocks,threads>>>(
          grid.packed_accessor64<float,3,torch::RestrictPtrTraits>(),
          output_count.packed_accessor64<int,3,torch::RestrictPtrTraits>(),
          grad_output.packed_accessor64<float,4,torch::RestrictPtrTraits>(),
          grad_input.packed_accessor64<float,3,torch::RestrictPtrTraits>()
          );

//    }
//    ));
  return grad_input;
}

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def("grid_voxel_2d_cuda_forward", &grid_voxel_2d_cuda_forward, "grid_voxel_2d_cuda");
  m.def("grid_voxel_2d_cuda_backward", &grid_voxel_2d_cuda_backward, "grid_voxel_2d_backward_cuda");
}