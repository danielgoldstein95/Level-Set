/* Julian Gutierrez
 * Northeastern University
 * High Performance Computing
 * 
 * Sobel Algorithm Implementation 
 *  
 */
 
#include "sobel.h"

/*******************************************************/
/*                 Cuda Error Function                 */
/*******************************************************/
inline cudaError_t checkCuda(cudaError_t result) {
	#if defined(DEBUG) || defined(_DEBUG)
		if (result != cudaSuccess) {
			fprintf(stderr, "CUDA Runtime Error: %s\n", cudaGetErrorString(result));
			exit(-1);
		}
	#endif
		return result;
}

using namespace std;

void modThreshold (unsigned int value){
	threshold = value;
}

/*
 * Sobel Kernel
 */
__global__ void sobelAlgorithm(unsigned char *intensity, 
				unsigned char *result,
				unsigned int threshold){

	int tx = threadIdx.x;
	int ty = threadIdx.y;
	int bx = blockIdx.x;
	int by = blockIdx.y;
	
	// Including border
	__shared__ unsigned char   inTile[TILE_SIZE+2][TILE_SIZE+2]; // input
	__shared__ unsigned char  outTile[TILE_SIZE+2][TILE_SIZE+2]; // output

	// Read Input Data into Shared Memory
	/////////////////////////////////////////////////////////////////////////////////////

	int x = bx<<BTSB;
	x = x + tx;
	x = x<<TTSB;
	int y = by<<BTSB;
	y = y + ty;
	y = y<<TTSB;
	  
	int sharedX = tx*THREAD_TILE_SIZE+1;
	int sharedY = ty*THREAD_TILE_SIZE+1;
	
	int location = 	y*(gridDim.x*TILE_SIZE) + x;
	inTile[sharedY  ][sharedX  ] = intensity[location];
	location = 	y*(gridDim.x*TILE_SIZE) + (x + 1);
	inTile[sharedY  ][sharedX+1] = intensity[location];
	location = 	(y + 1)*(gridDim.x*TILE_SIZE) + x;
	inTile[sharedY+1][sharedX  ] = intensity[location];
	location = 	(y + 1)*(gridDim.x*TILE_SIZE) + (x + 1);
	inTile[sharedY+1][sharedX+1] = intensity[location];
		
	// Read Border Data into Shared Memory
	/////////////////////////////////////////////////////////////////////////////////////
	
	int borderXLoc = 0;
	int borderYLoc = 0;
	
	// Needed Variables
	int bLocation;
	
	// Update horizontal border
	borderXLoc = sharedX;
	if (ty == 0 ){		
		// Location to write in shared memory
		borderYLoc = 0;
		if (by != 0) {
			// Upper block border
			y-=1;
		}
	} else if (ty == BLOCK_TILE_SIZE-1){
		// Location to write in shared memory
		borderYLoc = TILE_SIZE+1;			
		if (by != gridDim.y-1) {
			// Lower block border
			y+=THREAD_TILE_SIZE;
		}
	}
	// Read from global and write to shared memory
	if (ty == 0 || ty == BLOCK_TILE_SIZE-1) {
		if ((by == 0           && ty == 0                ) || 
		    (by == gridDim.y-1 && ty == BLOCK_TILE_SIZE-1)){
			inTile[borderYLoc][borderXLoc  ] = 0;
			inTile[borderYLoc][borderXLoc+1] = 0;
		} else {
			bLocation = y*(gridDim.x*TILE_SIZE) + x;
			inTile[borderYLoc][borderXLoc  ] = intensity[bLocation];
			bLocation = y*(gridDim.x*TILE_SIZE) + (x + 1);
			inTile[borderYLoc][borderXLoc+1] = intensity[bLocation];
		}
	}
		
	// Update vertical border
	x = bx<<BTSB;
	x = x + tx;
	x = x<<TTSB;
	y = by<<BTSB;
	y = y + ty;
	y = y<<TTSB;
	
	borderYLoc = sharedY;
	if (tx == 0 ){		
		// Location to write in shared memory
		borderXLoc = 0;
		if (bx != 0) {
			// Upper block border
			x-=1;
		}
	} else if (tx == BLOCK_TILE_SIZE-1){
		// Location to write in shared memory
		borderXLoc = TILE_SIZE+1;			
		if (bx != gridDim.x-1) {
			// Lower block border
			x+=THREAD_TILE_SIZE;
		}
	}
	// Read from global and write to shared memory
	if (tx == 0 || tx == BLOCK_TILE_SIZE-1) {
		if ((bx == 0           && tx == 0                ) || 
		    (bx == gridDim.x-1 && tx == BLOCK_TILE_SIZE-1)){
			inTile[borderYLoc  ][borderXLoc  ] = 0;
			inTile[borderYLoc+1][borderXLoc] = 0;
		} else {
			bLocation = y*(gridDim.x*TILE_SIZE) + x;
			inTile[borderYLoc  ][borderXLoc  ] = intensity[bLocation];
			bLocation = (y+1)*(gridDim.x*TILE_SIZE) + x;
			inTile[borderYLoc+1][borderXLoc  ] = intensity[bLocation];
		}
	}
	
	x = bx<<BTSB;
	x = x + tx;
	x = x<<TTSB;
	y = by<<BTSB;
	y = y + ty;
	y = y<<TTSB;
	
	// Corners for Border
	if ((tx == 0 || tx == BLOCK_TILE_SIZE-1) && (ty == 0 || ty == BLOCK_TILE_SIZE-1)){
		if (tx == 0) {
			borderXLoc = 0;
			x-=1;
		} else {
			borderXLoc = TILE_SIZE+1;
			x+=THREAD_TILE_SIZE;
		}
		
		if (ty == 0) {
			borderYLoc = 0;
			y-=1;
		} else {
			borderYLoc = TILE_SIZE+1;
			y+=THREAD_TILE_SIZE;
		}
		if (
			((tx == 0                 && ty == 0                ) && 
			 (bx == 0                 || by == 0               )) || 
			((tx == 0                 && ty == BLOCK_TILE_SIZE-1) &&
			 (bx == 0                 || by == gridDim.y-1     )) ||
			((tx == BLOCK_TILE_SIZE-1 && ty == 0                ) &&
			 (bx == gridDim.x-1       || by == 0               )) ||
			((tx == BLOCK_TILE_SIZE-1 && ty == BLOCK_TILE_SIZE-1) &&
			 (bx == gridDim.x-1       || by == gridDim.y-1     ))
		     ){
			inTile[borderYLoc][borderXLoc] = 0;
		} else {
			bLocation = y*(gridDim.x*TILE_SIZE) + x;
			inTile[borderYLoc][borderXLoc] = intensity [bLocation];
		}
	}
	
	__syncthreads();
	
	// Algorithm 
	/////////////////////////////////////////////////////////////////////

	for (int tempY = ty+1; tempY <= TILE_SIZE; tempY+=BLOCK_TILE_SIZE ){
		for (int tempX = tx+1; tempX <= TILE_SIZE; tempX+=BLOCK_TILE_SIZE ){
			int sum1 =      inTile[tempY-1][tempX+1] - inTile[tempY-1][tempX-1] 
				 + 2 * (inTile[tempY  ][tempX+1] - inTile[tempY  ][tempX-1])
				 +      inTile[tempY+1][tempX+1] - inTile[tempY+1][tempX-1];
			int sum2 =      inTile[tempY-1][tempX-1] + inTile[tempY-1][tempX+1]
				 + 2 * (inTile[tempY-1][tempX  ] - inTile[tempY+1][tempX  ])
				 -      inTile[tempY+1][tempX-1] - inTile[tempY+1][tempX+1];

			int magnitude = sum1*sum1+sum2*sum2;
			
			if(magnitude > threshold)
				outTile[tempY][tempX] = 255;
			else 
				outTile[tempY][tempX] = 0;
		}
	} 
	
	__syncthreads();
	
	x = bx<<BTSB;
	x = x + tx;
	x = x<<TTSB;
	y = by<<BTSB;
	y = y + ty;
	y = y<<TTSB;
	
	// Write back result
	location         = y      *(gridDim.x*TILE_SIZE) + x;
	result[location] = outTile[sharedY  ][sharedX  ];
	location         = y      *(gridDim.x*TILE_SIZE) + (x + 1);
	result[location] = outTile[sharedY  ][sharedX+1];
	location         = (y + 1)*(gridDim.x*TILE_SIZE) + x;
	result[location] = outTile[sharedY+1][sharedX  ];
	location         = (y + 1)*(gridDim.x*TILE_SIZE) + (x + 1);
	result[location] = outTile[sharedY+1][sharedX+1];
	
}

unsigned char *sobel(unsigned char *intensity,
		unsigned int height, 
		unsigned int width){
	
	#if defined(DEBUG)
		printf("Printing input data\n");
		printf("Height: %d\n", height);
		printf("Width: %d\n", width);
	#endif
	
	int gridXSize = 1 + (( width - 1) / TILE_SIZE);
	int gridYSize = 1 + ((height - 1) / TILE_SIZE);
	
	int XSize = gridXSize*TILE_SIZE;
	int YSize = gridYSize*TILE_SIZE;
	
	// Both are the same size (CPU/GPU).
	gpu.size = XSize*YSize;
	
	// Allocate arrays in GPU memory
	#if defined(VERBOSE)
		printf ("Allocating arrays in GPU memory.\n");
	#endif
	
	#if defined(CUDA_TIMING)
		float Ttime;
		TIMER_CREATE(Ttime);
		TIMER_START(Ttime);
	#endif
	
	checkCuda(cudaMalloc((void**)&gpu.intensity              , gpu.size*sizeof(char)));
	checkCuda(cudaMalloc((void**)&gpu.result                 , gpu.size*sizeof(char)));
	
	// Allocate result array in CPU memory
	gpu.resultOnCPU = new unsigned char[gpu.size];
				
        checkCuda(cudaMemcpy(gpu.intensity, 
			intensity, 
			gpu.size*sizeof(char), 
			cudaMemcpyHostToDevice));

	checkCuda(cudaDeviceSynchronize());

	#if defined(CUDA_TIMING)
		float Ktime;
		TIMER_CREATE(Ktime);
		TIMER_START(Ktime);
	#endif
	
	#if defined(VERBOSE)
		printf("Running algorithm on GPU.\n");
	#endif
	
	dim3 dimGrid(gridXSize, gridYSize);
        dim3 dimBlock(BLOCK_TILE_SIZE, BLOCK_TILE_SIZE);
	
	// Launch kernel to begin image segmenation
	sobelAlgorithm<<<dimGrid, dimBlock>>>(gpu.intensity, 
					      gpu.result,
					      threshold);
	
	checkCuda(cudaDeviceSynchronize());

	#if defined(CUDA_TIMING)
		TIMER_END(Ktime);
		printf("Kernel Execution Time: %f ms\n", Ktime);
	#endif
	
	// Retrieve results from the GPU
	checkCuda(cudaMemcpy(gpu.resultOnCPU, 
			gpu.result, 
			gpu.size*sizeof(char), 
			cudaMemcpyDeviceToHost));
			
	// Free resources and end the program
	checkCuda(cudaFree(gpu.intensity));
	checkCuda(cudaFree(gpu.result));
	
	#if defined(CUDA_TIMING)
		TIMER_END(Ttime);
		printf("Total GPU Execution Time: %f ms\n", Ttime);
	#endif
	
	return(gpu.resultOnCPU);

}

unsigned char *sobelWarmup(unsigned char *intensity,
		unsigned int height, 
		unsigned int width){

	int gridXSize = 1 + (( width - 1) / TILE_SIZE);
	int gridYSize = 1 + ((height - 1) / TILE_SIZE);
	
	int XSize = gridXSize*TILE_SIZE;
	int YSize = gridYSize*TILE_SIZE;
	
	// Both are the same size (CPU/GPU).
	gpu.size = XSize*YSize;
	
	// Allocate arrays in GPU memory
	checkCuda(cudaMalloc((void**)&gpu.intensity              , gpu.size*sizeof(char)));
	checkCuda(cudaMalloc((void**)&gpu.result                 , gpu.size*sizeof(char)));
	
	// Allocate result array in CPU memory
	gpu.resultOnCPU = new unsigned char[gpu.size];
				
        checkCuda(cudaMemcpy(gpu.intensity, 
			intensity, 
			gpu.size*sizeof(char), 
			cudaMemcpyHostToDevice));

	checkCuda(cudaDeviceSynchronize());

	dim3 dimGrid(gridXSize, gridYSize);
        dim3 dimBlock(BLOCK_TILE_SIZE, BLOCK_TILE_SIZE);
	
	// Launch kernel to begin image segmenation
	sobelAlgorithm<<<dimGrid, dimBlock>>>(gpu.intensity, 
					      gpu.result,
					      threshold);
	
	checkCuda(cudaDeviceSynchronize());

	// Retrieve results from the GPU
	checkCuda(cudaMemcpy(gpu.resultOnCPU, 
			gpu.result, 
			gpu.size*sizeof(char), 
			cudaMemcpyDeviceToHost));
			
	// Free resources and end the program
	checkCuda(cudaFree(gpu.intensity));
	checkCuda(cudaFree(gpu.result));
	
	return(gpu.resultOnCPU);

}