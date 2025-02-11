#include <iostream>
#include <cstring>
#include <cmath>

#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include "freehand_reconstruction_GPU.cuh"
#include "FreehandReconstruction.h"

__constant__ float ImageToVolume_DeviceConstant[640 * 16];

__constant__ int VOL_DIM_X;
__constant__ int VOL_DIM_Y;
__constant__ int VOL_DIM_Z;

__constant__ int US_DIM_X;
__constant__ int US_DIM_Y;
__constant__ int FRAME_NUMBER;

#define BLOCK_SIZE_X 16
#define BLOCK_SIZE_Y 16
#define BLOCK_SIZE_Z 2

#define GROUPING_SIZE 3
#define INTERP_KERNEL_RADIUS 1
#define HOLEFILLING_KERNEL_RADIUS 3

__device__ int GetPxlIdx(int col_idx, int row_idx, int pag_idx) {
    return col_idx + row_idx * blockDim.x * gridDim.x + pag_idx * blockDim.x * gridDim.x * blockDim.y * gridDim.y;
}

__global__ void HoleFilling_GPU(float *Volume_distributed, uint8_t *Volume_d, float *Weighting_d) {
    int col_idx = threadIdx.x + blockIdx.x * blockDim.x;
    int row_idx = threadIdx.y + blockIdx.y * blockDim.y;
    int pag_idx = threadIdx.z + blockIdx.z * blockDim.z;

    int Vol_idx = col_idx + row_idx * VOL_DIM_X + pag_idx * VOL_DIM_X * VOL_DIM_Y; //GetPxlIdx(col_idx, row_idx, pag_idx);

    if (col_idx < VOL_DIM_X && row_idx < VOL_DIM_Y && pag_idx < VOL_DIM_Z) {

        if (Volume_distributed[Vol_idx] != 0)
        {
            Volume_d[Vol_idx] = Volume_distributed[Vol_idx];
            return;
        }
        float accumulateInvDistance = 0;
        int Acc_NotZeroVoxel = 0;
        float Acc_Sum = 0.0;
        int frame1Index = -1, frame2Index = -1;
        float minDistance = 900, secondMinDistance = 900;
        float firstPixelValue = 0, secondPixelValue = 0;
        {//Accumulate the not zero voxels:
            for (int k_z = 0 - HOLEFILLING_KERNEL_RADIUS; k_z < 1 + HOLEFILLING_KERNEL_RADIUS; ++k_z) {
                for (int k_y = 0 - HOLEFILLING_KERNEL_RADIUS; k_y < 1 + HOLEFILLING_KERNEL_RADIUS; ++k_y) {
                    for (int k_x = 0 - HOLEFILLING_KERNEL_RADIUS; k_x < 1 + HOLEFILLING_KERNEL_RADIUS; ++k_x) {
                        //check if the current selected pixel [x, y, z] is out of bound:
                        int Selected_Pxl[3] = { col_idx + k_x, row_idx + k_y, pag_idx + k_z };
                        if ((Selected_Pxl[0] >= 0 && Selected_Pxl[0] < VOL_DIM_X) &&
                            (Selected_Pxl[1] >= 0 && Selected_Pxl[1] < VOL_DIM_Y) &&
                            (Selected_Pxl[2] >= 0 && Selected_Pxl[2] < VOL_DIM_Z)) {
                            int selectedVoxel = Selected_Pxl[0] + Selected_Pxl[1] * VOL_DIM_X + Selected_Pxl[2] * VOL_DIM_X * VOL_DIM_Y;
                            if (Volume_distributed[selectedVoxel] != 0.0f) {
                                float distanceSquarred = (k_x * k_x + k_y * k_y + k_z * k_z);
                                if (distanceSquarred < minDistance)
                                {
                                    secondMinDistance = minDistance;
                                    secondPixelValue = firstPixelValue;
                                    minDistance = distanceSquarred;
                                    firstPixelValue = Volume_distributed[selectedVoxel];
                                }
                                else if (distanceSquarred < secondMinDistance)
                                {
                                    secondMinDistance = distanceSquarred;
                                    secondPixelValue = Volume_distributed[selectedVoxel];
                                }
                                Acc_NotZeroVoxel = 1;
                            }
                        }
                    }
                }
            }
        }
        if (Acc_NotZeroVoxel == 1) {
            Acc_Sum = firstPixelValue * (1 / minDistance) + secondPixelValue * (1 / secondMinDistance);
            accumulateInvDistance = (1 / minDistance) + (1 / secondMinDistance);
            float outputValue = Acc_Sum / accumulateInvDistance;
            if (outputValue >= 0 || outputValue <= 255) {
                Volume_d[Vol_idx] = (uint8_t)round(outputValue);
            }
            else {
                Volume_d[Vol_idx] = 0;
            }
        }
    }
}

__device__ void Matrix4x4MultiplyPoint(const float* point_in, float* point_out, int frame_idx) {
    float sum_tmp = 0.0f;
    for (int it_row = 0; it_row < 4; ++it_row) {
        for (int it_col = 0; it_col < 4; ++it_col) {
            sum_tmp += ImageToVolume_DeviceConstant[frame_idx * 16 + it_row * 4 + it_col] * point_in[it_col];
        }
        point_out[it_row] = sum_tmp;
        sum_tmp = 0.0f;
    }
}

__global__ void US_Distribution_GPU(float* Volume_d, float* Weighting_d, uint8_t* US_Frame_d,
    //Parameters for Volume:
    float Vxl_size_x, float Vxl_size_y, float Vxl_size_z,
    float Vol_Ori_x, float Vol_Ori_y, float Vol_Ori_z
) {

    int frm_idx = (threadIdx.z + blockIdx.z * blockDim.z) * GROUPING_SIZE;
    int col_idx = (threadIdx.x + blockIdx.x * blockDim.x) * GROUPING_SIZE;
    int row_idx = (threadIdx.y + blockIdx.y * blockDim.y) * GROUPING_SIZE;

    for (int it_frame = 0; it_frame < GROUPING_SIZE; ++it_frame) {

        for (int it_row = 0; it_row < GROUPING_SIZE; ++it_row) {

            for (int it_col = 0; it_col < GROUPING_SIZE; ++it_col) {

                //Iteration starts:
                if (frm_idx < FRAME_NUMBER && row_idx < US_DIM_Y && col_idx < US_DIM_X) {
                    //Get US pxl under volume, from pxl to [mm]:
                    float US_pxl[4] = { float(col_idx), float(row_idx), 0.0, 1.0 };
                    float US_pxl_Under_Vol[4] = { 0.0f };
                    Matrix4x4MultiplyPoint(US_pxl, US_pxl_Under_Vol, frm_idx);
                    //Derive pxl under volume in [mm] to [VOXEL]:
                    float Vxl_From_US_Pxl[3] = { roundf((US_pxl_Under_Vol[0] - Vol_Ori_x) / Vxl_size_x), roundf((US_pxl_Under_Vol[1] - Vol_Ori_y) / Vxl_size_y), roundf((US_pxl_Under_Vol[2] - Vol_Ori_z) / Vxl_size_z) };
                    float voxelFromUsPixelExact[3] = { (US_pxl_Under_Vol[0] - Vol_Ori_x) / Vxl_size_x , (US_pxl_Under_Vol[1] - Vol_Ori_y) / Vxl_size_y,(US_pxl_Under_Vol[2] - Vol_Ori_z) / Vxl_size_z };

                    for (int it_x = 0 - INTERP_KERNEL_RADIUS; it_x < INTERP_KERNEL_RADIUS; ++it_x) {

                        for (int it_y = 0 - INTERP_KERNEL_RADIUS; it_y < INTERP_KERNEL_RADIUS; ++it_y) {

                            for (int it_z = 0 - INTERP_KERNEL_RADIUS; it_z < INTERP_KERNEL_RADIUS; ++it_z) {

                                ////assign the pixel value to the nearest voxel
                                int select_x = Vxl_From_US_Pxl[0] + it_x;
                                int select_y = Vxl_From_US_Pxl[1] + it_y;
                                int select_z = Vxl_From_US_Pxl[2] + it_z;
                                if ((select_x < VOL_DIM_X) && (select_x >= 0) &&
                                    (select_y < VOL_DIM_Y) && (select_y >= 0) &&
                                    (select_z < VOL_DIM_Z) && (select_z >= 0)) {
                                    //Calculate inverse distance: [voxel] to US [pixel]:
                                    float inv_distance = exp(-sqrt(
                                        ((select_x * Vxl_size_x + Vol_Ori_x) - US_pxl_Under_Vol[0]) *
                                        ((select_x * Vxl_size_x + Vol_Ori_x) - US_pxl_Under_Vol[0]) +
                                        ((select_y * Vxl_size_y + Vol_Ori_y) - US_pxl_Under_Vol[1]) *
                                        ((select_y * Vxl_size_y + Vol_Ori_y) - US_pxl_Under_Vol[1]) +
                                        ((select_z * Vxl_size_z + Vol_Ori_z) - US_pxl_Under_Vol[2]) *
                                        ((select_z * Vxl_size_z + Vol_Ori_z - US_pxl_Under_Vol[2]))));
                                    float sum = Volume_d[select_x + select_y * VOL_DIM_X + select_z * VOL_DIM_X * VOL_DIM_Y] * Weighting_d[select_x + select_y * VOL_DIM_X + select_z * VOL_DIM_X * VOL_DIM_Y] +
                                    US_Frame_d[col_idx + row_idx * US_DIM_X + frm_idx * US_DIM_X * US_DIM_Y] * inv_distance;
                                    Weighting_d[select_x + select_y * VOL_DIM_X + select_z * VOL_DIM_X * VOL_DIM_Y] += inv_distance;
                                    Volume_d[select_x + select_y * VOL_DIM_X + select_z * VOL_DIM_X * VOL_DIM_Y] = sum / Weighting_d[select_x + select_y * VOL_DIM_X + select_z * VOL_DIM_X * VOL_DIM_Y];
                                }
                            }
                        }
                    }

                }
                ++col_idx;
            }
            ++row_idx;
        }
        ++frm_idx;
    }

}

__global__ void GetXY_plane(float *Volume_d, float *plane_d, int Location) {
    int col_idx = threadIdx.x + blockIdx.x * blockDim.x;
    int row_idx = threadIdx.y + blockIdx.y * blockDim.y;

    int Vol_x_idx = col_idx;
    int Vol_y_idx = row_idx;
    int Vol_z_idx = Location;

    if (col_idx < VOL_DIM_X && row_idx < VOL_DIM_Y) {
        plane_d[col_idx + row_idx * VOL_DIM_X] = Volume_d[Vol_x_idx + Vol_y_idx * VOL_DIM_X + Vol_z_idx * VOL_DIM_X * VOL_DIM_Y];
    }
}

__global__ void GetXZ_plane(float *Volume_d, float *plane_d, int Location) {
    int col_idx = threadIdx.x + blockIdx.x * blockDim.x;
    int row_idx = threadIdx.y + blockIdx.y * blockDim.y;

    int Vol_x_idx = col_idx;
    int Vol_y_idx = Location;
    int Vol_z_idx = row_idx;

    if (col_idx < VOL_DIM_X && row_idx < VOL_DIM_Z) {
        plane_d[col_idx + row_idx * VOL_DIM_X] = Volume_d[Vol_x_idx + Vol_y_idx * VOL_DIM_X + Vol_z_idx * VOL_DIM_X * VOL_DIM_Y];
    }
}

__global__ void GetYZ_plane(float *Volume_d, float *plane_d, int Location) {
    int col_idx = threadIdx.x + blockIdx.x * blockDim.x;
    int row_idx = threadIdx.y + blockIdx.y * blockDim.y;

    int Vol_x_idx = Location;
    int Vol_y_idx = row_idx;
    int Vol_z_idx = col_idx;

    if (col_idx < VOL_DIM_Z && row_idx < VOL_DIM_Y) {
        plane_d[col_idx + row_idx * VOL_DIM_Z] = Volume_d[Vol_x_idx + Vol_y_idx * VOL_DIM_X + Vol_z_idx * VOL_DIM_X * VOL_DIM_Y];
    }
}

void GPU_Setups(const ImageBase::us_parameters_structure US_Params, const ImageBase::volume_parameters_structure Vol_Params, const int NumFrames, const float* TotalMatrices, float* Recon_Volume, float* Weighting_Volume, uint8_t *VolumeTosave, uint8_t* US_Frames) {

    cudaMemcpyToSymbol(ImageToVolume_DeviceConstant, TotalMatrices, NumFrames * 16 * sizeof(float));

    cudaMemcpyToSymbol(VOL_DIM_X, &Vol_Params.dim_vxl.x, sizeof(int));
    cudaMemcpyToSymbol(VOL_DIM_Y, &Vol_Params.dim_vxl.y, sizeof(int));
    cudaMemcpyToSymbol(VOL_DIM_Z, &Vol_Params.dim_vxl.z, sizeof(int));

    cudaMemcpyToSymbol(US_DIM_X, &US_Params.dim_pxl.x, sizeof(int));
    cudaMemcpyToSymbol(US_DIM_Y, &US_Params.dim_pxl.y, sizeof(int));

    cudaMemcpyToSymbol(FRAME_NUMBER, &NumFrames, sizeof(int));
    printf("FreehandReconstruction -- Runtime check 0:%s\n", cudaGetErrorString(cudaGetLastError()));
    //Allocate GPU memory:
    float   *Volume_d = NULL;
    float   *Weighting_d = NULL;
    uint8_t *US_Frame_d = NULL;

    cudaMalloc((void **)&Volume_d, Vol_Params.dim_vxl.x * Vol_Params.dim_vxl.y * Vol_Params.dim_vxl.z * sizeof(float));
    cudaMalloc((void **)&Weighting_d, Vol_Params.dim_vxl.x * Vol_Params.dim_vxl.y * Vol_Params.dim_vxl.z * sizeof(float));
    cudaMalloc((void **)&US_Frame_d, US_Params.dim_pxl.x * US_Params.dim_pxl.y * NumFrames * sizeof(uint8_t));
    printf("FreehandReconstruction -- Runtime check 1:%s\n", cudaGetErrorString(cudaGetLastError()));
    //Copy mem from host RAM to device RAM:
    cudaMemcpy(US_Frame_d, US_Frames, US_Params.dim_pxl.x * US_Params.dim_pxl.y * NumFrames * sizeof(uint8_t), cudaMemcpyHostToDevice);
    cudaMemcpy(Weighting_d, Weighting_Volume, Vol_Params.dim_vxl.x * Vol_Params.dim_vxl.y * Vol_Params.dim_vxl.z * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(Volume_d, Recon_Volume, Vol_Params.dim_vxl.x * Vol_Params.dim_vxl.y * Vol_Params.dim_vxl.z * sizeof(float), cudaMemcpyHostToDevice);
    printf("FreehandReconstruction -- Runtime check 2:%s\n", cudaGetErrorString(cudaGetLastError()));
    /*------------------------------------------- Perform Distribution ------------------------------------------ */
    //Define threads distribution:
    dim3 BlockDim_Distribution(
        BLOCK_SIZE_X,
        BLOCK_SIZE_Y,
        BLOCK_SIZE_Z
    );
    dim3 GridDim_Distribution(
        int(ceil(float(US_Params.dim_pxl.x) / BLOCK_SIZE_X / float(GROUPING_SIZE))),
        int(ceil(float(US_Params.dim_pxl.y) / BLOCK_SIZE_Y / float(GROUPING_SIZE))),
        int(ceil(float(NumFrames) / BLOCK_SIZE_Z / float(GROUPING_SIZE)))
    );
    printf("FreehandReconstruction -- Runtime check 3:%s\n", cudaGetErrorString(cudaGetLastError()));
    US_Distribution_GPU << <GridDim_Distribution, BlockDim_Distribution >> >(Volume_d, Weighting_d, US_Frame_d, Vol_Params.v_size_mm.x, Vol_Params.v_size_mm.y, Vol_Params.v_size_mm.z, Vol_Params.origin_mm.x, Vol_Params.origin_mm.y, Vol_Params.origin_mm.z);
    cudaDeviceSynchronize();
    printf("FreehandReconstruction -- Runtime check 4:%s\n", cudaGetErrorString(cudaGetLastError()));

    /*----------------------------------------------- Hole Filling ---------------------------------------------- */
    //Prepare the final output uint8_t volume: 
    uint8_t *volume_ToSave_d = NULL;
    cudaMalloc((void **)&volume_ToSave_d, Vol_Params.dim_vxl.x * Vol_Params.dim_vxl.y * Vol_Params.dim_vxl.z * sizeof(uint8_t));

    dim3 BlockDim_HoleFilling(
        BLOCK_SIZE_X,
        BLOCK_SIZE_Y,
        BLOCK_SIZE_Z
    );
    dim3 GridDim_HoleFilling(
        int(ceil(float(Vol_Params.dim_vxl.x) / BLOCK_SIZE_X)),
        int(ceil(float(Vol_Params.dim_vxl.y) / BLOCK_SIZE_Y)),
        int(ceil(float(Vol_Params.dim_vxl.z) / BLOCK_SIZE_Z))
    );
    cudaDeviceSynchronize();
    printf("FreehandReconstruction -- Runtime check 5:%s\n", cudaGetErrorString(cudaGetLastError()));
    HoleFilling_GPU <<<GridDim_HoleFilling, BlockDim_HoleFilling >>>(Volume_d,volume_ToSave_d, Weighting_d );
    cudaDeviceSynchronize();
    printf("FreehandReconstruction -- Runtime check 6:%s\n", cudaGetErrorString(cudaGetLastError()));

    //Complete the remaining memory transfer:
    cudaMemcpy(Recon_Volume, Volume_d, Vol_Params.dim_vxl.x * Vol_Params.dim_vxl.y * Vol_Params.dim_vxl.z * sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(Weighting_Volume, Weighting_d, Vol_Params.dim_vxl.x * Vol_Params.dim_vxl.y * Vol_Params.dim_vxl.z * sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(VolumeTosave, volume_ToSave_d, Vol_Params.dim_vxl.x * Vol_Params.dim_vxl.y * Vol_Params.dim_vxl.z * sizeof(uint8_t), cudaMemcpyDeviceToHost);

    cudaFree(Volume_d);
    cudaFree(Weighting_d);
    cudaFree(US_Frame_d);
    cudaFree(volume_ToSave_d);
    cudaDeviceSynchronize();
}
