/* Julian Gutierrez
 * Northeastern University
 * High Performance Computing
 * 
 * Level Set Segmentation for Image Processing 
 *  
 */
 
#include "lss.h"

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

void modMaxIter (int value){
	max_iterations = value;
}

/*
 * Lss Step 1 from Pseudo Code
 */
__global__ void lssStep1(
		unsigned char* intensity, 
		unsigned char* labels,
		unsigned char* phi, 
		int targetLabel, 
		int lowerIntensityBound, 
		int upperIntensityBound,
		unsigned int* globalBlockIndicator ) {

	int tx = threadIdx.x;
	int ty = threadIdx.y;
	int bx = blockIdx.x;
	int by = blockIdx.y;

	int blockId = by*gridDim.x+bx;
				
	// Excluding border
	__shared__ unsigned char intensityTile[TILE_SIZE][TILE_SIZE]; // input
	__shared__ unsigned char     labelTile[TILE_SIZE][TILE_SIZE]; // input
	__shared__ unsigned char       phiTile[TILE_SIZE][TILE_SIZE]; // output
	
	// Flags
	__shared__ volatile int localGBI;
		
	// Read Input Data into Shared Memory
	/////////////////////////////////////////////////////////////////////////////////////

	int x = bx<<BTSB;
	x = x + tx;
	x = x<<TTSB;
	int y = by<<BTSB;
	y = y + ty;
	y = y<<TTSB;
	
	int sharedX = tx*THREAD_TILE_SIZE;
	int sharedY = ty*THREAD_TILE_SIZE;
	  
	int location = 	(y    )*(gridDim.x*TILE_SIZE) + (x    );
	intensityTile[sharedY  ][sharedX  ] = intensity[location];
	    labelTile[sharedY  ][sharedX  ] = labels[location];
	
	location = 	(y    )*(gridDim.x*TILE_SIZE) + (x + 1);
	intensityTile[sharedY  ][sharedX+1] = intensity[location];
	    labelTile[sharedY  ][sharedX+1] = labels[location];
	
	location = 	(y + 1)*(gridDim.x*TILE_SIZE) + (x    );
	intensityTile[sharedY+1][sharedX  ] = intensity[location];
	    labelTile[sharedY+1][sharedX  ] = labels[location];
	
	location = 	(y + 1)*(gridDim.x*TILE_SIZE) + (x + 1);
	intensityTile[sharedY+1][sharedX+1] = intensity[location];
	    labelTile[sharedY+1][sharedX+1] = labels[location];
	
	localGBI = 0;
	
	__syncthreads();
	
	// Algorithm 
	/////////////////////////////////////////////////////////////////////////////////////
	
	// Initialization
	for (int tempY = ty; tempY < TILE_SIZE; tempY+=BLOCK_TILE_SIZE ){
		for (int tempX = tx; tempX < TILE_SIZE; tempX+=BLOCK_TILE_SIZE ){
			
			int ownIntData = intensityTile[tempY][tempX];
			if(ownIntData >= lowerIntensityBound && 
			   ownIntData <= upperIntensityBound) {
				if (labelTile[tempY][tempX] == targetLabel)
					phiTile[tempY][tempX] = 3;
				else {
					localGBI = 1;
					phiTile[tempY][tempX] = 1;
				}
			} else {
				if (labelTile[tempY][tempX] == targetLabel){
					phiTile[tempY][tempX] = 4;
					localGBI = 1;
				} else {
					phiTile[tempY][tempX] = 0;
				}
			}
		}
	}
	__syncthreads();

	// Write back to main memory
	location         = y      *(gridDim.x*TILE_SIZE) + x;
	phi[location] = phiTile[sharedY  ][sharedX  ];
	location         = y      *(gridDim.x*TILE_SIZE) + (x + 1);
	phi[location] = phiTile[sharedY  ][sharedX+1];
	location         = (y + 1)*(gridDim.x*TILE_SIZE) + x;
	phi[location] = phiTile[sharedY+1][sharedX  ];
	location         = (y + 1)*(gridDim.x*TILE_SIZE) + (x + 1);
	phi[location] = phiTile[sharedY+1][sharedX+1];
	
	if (tx == 0 && ty == 0 && localGBI){
		globalBlockIndicator[blockId] = 1;
	}
}
	
/*
 * Lss Step 2 from Pseudo Code
 */
__global__ void lssStep2(
		unsigned char* phi, 
		unsigned int* globalBlockIndicator,
		unsigned int* globalFinishedVariable){

	int tx = threadIdx.x;
	int ty = threadIdx.y;
	int bx = blockIdx.x;
	int by = blockIdx.y;
	
	int blockId = by*gridDim.x+bx;
	
	// Including border
	__shared__ unsigned char    phiTile[TILE_SIZE+2][TILE_SIZE+2]; // input/output

	// Flags
	__shared__ volatile char BlockChange;
	__shared__ volatile char change;
	__shared__ volatile int redoBlock;
		
	// Read Global Block Indicator from global memory
	int localGBI = globalBlockIndicator[blockId];
	
	// Set Block Variables
	redoBlock = 0;
	
	__syncthreads();
	
	if (localGBI > 0) {
		
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
		phiTile[sharedY  ][sharedX  ] = phi[location];
		location = 	y*(gridDim.x*TILE_SIZE) + (x + 1);
		phiTile[sharedY  ][sharedX+1] = phi[location];
		location = 	(y + 1)*(gridDim.x*TILE_SIZE) + x;
		phiTile[sharedY+1][sharedX  ] = phi[location];
		location = 	(y + 1)*(gridDim.x*TILE_SIZE) + (x + 1);
		phiTile[sharedY+1][sharedX+1] = phi[location];
		

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
				phiTile[borderYLoc][borderXLoc  ] = 0;
				phiTile[borderYLoc][borderXLoc+1] = 0;
			} else {
				bLocation = y*(gridDim.x*TILE_SIZE) + x;
				phiTile[borderYLoc][borderXLoc  ] = phi[bLocation];
				bLocation = y*(gridDim.x*TILE_SIZE) + (x + 1);
				phiTile[borderYLoc][borderXLoc+1] = phi[bLocation];
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
				phiTile[borderYLoc][borderXLoc  ] = 0;
				phiTile[borderYLoc+1][borderXLoc] = 0;
			} else {
				bLocation = y*(gridDim.x*TILE_SIZE) + x;
				phiTile[borderYLoc  ][borderXLoc  ] = phi[bLocation];
				bLocation = (y+1)*(gridDim.x*TILE_SIZE) + x;
				phiTile[borderYLoc+1][borderXLoc  ] = phi[bLocation];
			}
		}
		
		BlockChange = 0; // Shared variable
		change       = 1; // Shared variable
		__syncthreads();
		
		// Algorithm 
		/////////////////////////////////////////////////////////////////////

		while (change){
			__syncthreads();
			change = 0;
			__syncthreads();
			
			for (int tempY = ty+1; tempY <= TILE_SIZE; tempY+=BLOCK_TILE_SIZE ){
				for (int tempX = tx+1; tempX <= TILE_SIZE; tempX+=BLOCK_TILE_SIZE ){
					
					if( phiTile[tempY  ][tempX  ]  == 1 &&
					   (phiTile[tempY+1][tempX  ]  == 3 ||
					    phiTile[tempY-1][tempX  ]  == 3 ||
					    phiTile[tempY  ][tempX-1]  == 3 ||
					    phiTile[tempY  ][tempX+1]  == 3 )){
						phiTile  [tempY][tempX] = 3;
						change = 1;
						BlockChange = 1;
					} else if ( phiTile[tempY  ][tempX  ]  == 4 &&
					   (phiTile[tempY+1][tempX  ]  == 0 ||
					    phiTile[tempY-1][tempX  ]  == 0 ||
					    phiTile[tempY  ][tempX-1]  == 0 ||
					    phiTile[tempY  ][tempX+1]  == 0 )){
						phiTile  [tempY][tempX] = 0;
						change = 1;
						BlockChange = 1;
					}
				}
			}
			__syncthreads();
		}
		
		if (BlockChange){
			
			char phiData1 = phiTile[sharedY  ][sharedX  ];
			char phiData2 = phiTile[sharedY  ][sharedX+1];
			char phiData3 = phiTile[sharedY+1][sharedX  ];
			char phiData4 = phiTile[sharedY+1][sharedX+1];
			
			if (phiData1 ==  4 || phiData2 ==  4 || phiData3 ==  4 || phiData4 ==  4 ||
			    phiData1 == 1 || phiData2 == 1 || phiData3 == 1 || phiData4 == 1){
				redoBlock = 1;
			}
			
                        __syncthreads();
                        
                        x = bx<<BTSB;
                        x = x + tx;
                        x = x<<TTSB;
                        y = by<<BTSB;
                        y = y + ty;
                        y = y<<TTSB;
                        
                        location         = y      *(gridDim.x*TILE_SIZE) + x;
                        phi[location] = phiData1;
                        location         = y      *(gridDim.x*TILE_SIZE) + (x + 1);
                        phi[location] = phiData2;
                        location         = (y + 1)*(gridDim.x*TILE_SIZE) + x;
                        phi[location] = phiData3;
                        location         = (y + 1)*(gridDim.x*TILE_SIZE) + (x + 1);
                        phi[location] = phiData4;
                        
			if (tx == 0 && ty == 0) {
				if (!redoBlock){
					globalBlockIndicator[blockId] = 0;
				}
				*globalFinishedVariable = 1;
				__threadfence();
			}
		}
	}
}

/*
 * Lss Step 3 from Pseudo Code
 */
__global__ void lssStep3(
		unsigned char* phi,
		unsigned char* phiOut) {

	int tx = threadIdx.x;
	int ty = threadIdx.y;
	int bx = blockIdx.x;
	int by = blockIdx.y;
				
	// Including border
	__shared__ unsigned char    phiTile[TILE_SIZE+2][TILE_SIZE+2]; // input
	__shared__ unsigned char phiOutTile[TILE_SIZE+2][TILE_SIZE+2]; // output

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
	phiTile[sharedY  ][sharedX  ] = phi[location];
	location = 	y*(gridDim.x*TILE_SIZE) + (x + 1);
	phiTile[sharedY  ][sharedX+1] = phi[location];
	location = 	(y + 1)*(gridDim.x*TILE_SIZE) + x;
	phiTile[sharedY+1][sharedX  ] = phi[location];
	location = 	(y + 1)*(gridDim.x*TILE_SIZE) + (x + 1);
	phiTile[sharedY+1][sharedX+1] = phi[location];

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
			phiTile[borderYLoc][borderXLoc  ] = 0;
			phiTile[borderYLoc][borderXLoc+1] = 0;
		} else {
			bLocation = y*(gridDim.x*TILE_SIZE) + x;
			phiTile[borderYLoc][borderXLoc  ] = phi[bLocation];
			bLocation = y*(gridDim.x*TILE_SIZE) + (x + 1);
			phiTile[borderYLoc][borderXLoc+1] = phi[bLocation];
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
			phiTile[borderYLoc][borderXLoc  ] = 0;
			phiTile[borderYLoc+1][borderXLoc] = 0;
		} else {
			bLocation = y*(gridDim.x*TILE_SIZE) + x;
			phiTile[borderYLoc  ][borderXLoc  ] = phi[bLocation];
			bLocation = (y+1)*(gridDim.x*TILE_SIZE) + x;
			phiTile[borderYLoc+1][borderXLoc  ] = phi[bLocation];
		}
	}
	
	__syncthreads();
	
	// Algorithm 
	/////////////////////////////////////////////////////////////////////////////////////
	
	for (int tempY = ty+1; tempY <= TILE_SIZE; tempY+=BLOCK_TILE_SIZE ){
		for (int tempX = tx+1; tempX <= TILE_SIZE; tempX+=BLOCK_TILE_SIZE ){
			
			if(phiTile[tempY][tempX] > 2) {
				if(phiTile[tempY+1][tempX]  > 2 &&
				   phiTile[tempY-1][tempX]  > 2 &&
				   phiTile[tempY][tempX+1]  > 2 &&
				   phiTile[tempY][tempX-1]  > 2 ){
					phiOutTile[tempY][tempX] = 0xFD;
				} else 
					phiOutTile[tempY][tempX] = 0xFF;
			} else
				if(phiTile[tempY+1][tempX]  > 2 ||
				   phiTile[tempY-1][tempX]  > 2 ||
				   phiTile[tempY][tempX+1]  > 2 ||
				   phiTile[tempY][tempX-1]  > 2 ){
					phiOutTile[tempY][tempX] = 1;
				} else 
					phiOutTile[tempY][tempX] = 3;
		}
	}
	
	__syncthreads();
	
	x = bx<<BTSB;
	x = x + tx;
	x = x<<TTSB;
	y = by<<BTSB;
	y = y + ty;
	y = y<<TTSB;
	
	// Write back to main memory
	location         = y      *(gridDim.x*TILE_SIZE) + x;
	phiOut[location] = phiOutTile[sharedY  ][sharedX  ];
	location         = y      *(gridDim.x*TILE_SIZE) + (x + 1);
	phiOut[location] = phiOutTile[sharedY  ][sharedX+1];
	location         = (y + 1)*(gridDim.x*TILE_SIZE) + x;
	phiOut[location] = phiOutTile[sharedY+1][sharedX  ];
	location         = (y + 1)*(gridDim.x*TILE_SIZE) + (x + 1);
	phiOut[location] = phiOutTile[sharedY+1][sharedX+1];

}

__global__ void evolveContour(
		unsigned char* intensity, 
		unsigned char* labels,
		unsigned char* phi,
		unsigned char* phiOut, 
		int gridXSize,
		int gridYSize,
		int* targetLabels, 
		int* lowerIntensityBounds, 
		int* upperIntensityBounds,
		int max_iterations, 
		unsigned int* globalBlockIndicator,
		unsigned int* globalFinishedVariable,
		unsigned int* totalIterations ){
        int tid = threadIdx.x;
	
	// Setting up streams for 
	cudaStream_t stream;
	cudaStreamCreateWithFlags (&stream, cudaStreamNonBlocking);
	
	
	// Total iterations
	totalIterations = &totalIterations[tid];
	
	// Size in ints
	int size = (gridXSize*gridYSize)<<(TSB+TSB);
	
	// New phi pointer for each label.
	phi    = &phi[tid*size];
	phiOut = &phiOut[tid*size];

	globalBlockIndicator = &globalBlockIndicator[tid*gridXSize*gridYSize];

	// Global synchronization variable
	globalFinishedVariable = &globalFinishedVariable[tid];
	*globalFinishedVariable = 0;

	dim3 dimGrid(gridXSize, gridYSize);
        dim3 dimBlock(BLOCK_TILE_SIZE, BLOCK_TILE_SIZE);
	
	// Initialize phi array
	lssStep1<<<dimGrid, dimBlock, 0, stream>>>(intensity, 
					labels,  
					phi, 
					targetLabels[tid], 
					lowerIntensityBounds[tid], 
					upperIntensityBounds[tid],
					globalBlockIndicator );
	
	int iterations = 0;
	do {
		iterations++;
		lssStep2<<<dimGrid, dimBlock, 0, stream>>>(phi, 
					globalBlockIndicator,
					globalFinishedVariable );
		cudaDeviceSynchronize();
	} while (atomicExch(globalFinishedVariable,0) && (iterations < max_iterations));
	
	lssStep3<<<dimGrid, dimBlock, 0, stream>>>(phi,
					phiOut);
	
	*totalIterations = iterations;
}
		
unsigned char *levelSetSegment(
		unsigned char *intensity, 
		unsigned char *labels, 
		int height, 
		int width, 
		int *targetLabels, 
		int *lowerIntensityBounds,
		int *upperIntensityBounds,
		int numLabels){
	
	#if defined(DEBUG)
		printf("Printing input data\n");
		printf("Height: %d\n", height);
		printf("Width: %d\n", width);
		printf("Num Labels: %d\n", numLabels);
		
		for (int i = 0; i < numLabels; i++){
			printf("target label: %d\n", targetLabels[i]);
			printf("lower bound: %d\n", lowerIntensityBounds[i]);
			printf("upper bound: %d\n", upperIntensityBounds[i]);	
		}
	#endif
	
	int gridXSize = 1 + (( width - 1) / TILE_SIZE);
	int gridYSize = 1 + ((height - 1) / TILE_SIZE);
	
	#if defined(DEBUG)
		printf("\n Grid Size: %d %d\n", gridYSize, gridXSize);
		printf(  "Block Size: %d %d\n", BLOCK_TILE_SIZE, BLOCK_TILE_SIZE);
	#endif
	
	int XSize = gridXSize*TILE_SIZE;
	int YSize = gridYSize*TILE_SIZE;
	
	// Both are the same size (CPU/GPU).
	gpu.size = XSize*YSize*sizeof(char);
	
	// Allocate arrays in GPU memory
	#if defined(VERBOSE)
		printf ("Allocating arrays in GPU memory.\n");
	#endif
	
	#if defined(CUDA_TIMING)
		float Ttime;
		TIMER_CREATE(Ttime);
		TIMER_START(Ttime);
	#endif
	
	checkCuda(cudaMalloc((void**)&gpu.targetLabels           , numLabels*sizeof(int)));
        checkCuda(cudaMalloc((void**)&gpu.lowerIntensityBounds   , numLabels*sizeof(int)));
        checkCuda(cudaMalloc((void**)&gpu.upperIntensityBounds   , numLabels*sizeof(int)));
	checkCuda(cudaMalloc((void**)&gpu.intensity              , gpu.size));
	checkCuda(cudaMalloc((void**)&gpu.labels                 , gpu.size));
	checkCuda(cudaMalloc((void**)&gpu.phi                    , numLabels*gpu.size));
	checkCuda(cudaMalloc((void**)&gpu.phiOut                 , numLabels*gpu.size));
	checkCuda(cudaMalloc((void**)&gpu.globalBlockIndicator   , numLabels*gridXSize*gridYSize*sizeof(int)));
	checkCuda(cudaMalloc((void**)&gpu.globalFinishedVariable , numLabels*sizeof(int)));
	checkCuda(cudaMalloc((void**)&gpu.totalIterations        , numLabels*sizeof(int)));
	
	// Allocate result array in CPU memory
	gpu.phiOnCpu = new unsigned char[gpu.size*numLabels];
	gpu.totalIterationsOnCpu = new unsigned int [numLabels];
	
        checkCuda(cudaMemcpy(
			gpu.targetLabels, 
			targetLabels, 
			numLabels*sizeof(int), 
			cudaMemcpyHostToDevice));

        checkCuda(cudaMemcpy(
			gpu.lowerIntensityBounds, 
			lowerIntensityBounds, 
			numLabels*sizeof(int), 
			cudaMemcpyHostToDevice));

        checkCuda(cudaMemcpy(
			gpu.upperIntensityBounds, 
			upperIntensityBounds, 
			numLabels*sizeof(int), 
			cudaMemcpyHostToDevice));
			
        checkCuda(cudaMemcpy(
			gpu.intensity, 
			intensity, 
			gpu.size, 
			cudaMemcpyHostToDevice));
			
        checkCuda(cudaMemcpy(
			gpu.labels, 
			labels, 
			gpu.size, 
			cudaMemcpyHostToDevice));

	#if defined(KERNEL_TIMING)
		checkCuda(cudaDeviceSynchronize());
		float Ktime;
		TIMER_CREATE(Ktime);
		TIMER_START(Ktime);
	#endif
	
	#if defined(VERBOSE)
		printf("Running algorithm on GPU.\n");
	#endif
	
	// Launch kernel to begin image segmenation
	evolveContour<<<1, numLabels>>>(gpu.intensity, 
					gpu.labels,
					gpu.phi,
					gpu.phiOut, 
					gridXSize,
					gridYSize, 
					gpu.targetLabels, 
					gpu.lowerIntensityBounds, 
					gpu.upperIntensityBounds,
					max_iterations,
					gpu.globalBlockIndicator,
					gpu.globalFinishedVariable,
					gpu.totalIterations);
	

	#if defined(KERNEL_TIMING)
		checkCuda(cudaDeviceSynchronize());
		TIMER_END(Ktime);
		printf("Kernel Execution Time: %f ms\n", Ktime);
	#endif
	
	// Retrieve results from the GPU
	checkCuda(cudaMemcpy(
			gpu.phiOnCpu, 
			gpu.phiOut, 
			numLabels*gpu.size, 
			cudaMemcpyDeviceToHost));
	
	checkCuda(cudaMemcpy(
			gpu.totalIterationsOnCpu, 
			gpu.totalIterations, 
			numLabels*sizeof(int), 
			cudaMemcpyDeviceToHost));
			
	// Free resources and end the program
	checkCuda(cudaFree(gpu.intensity));
	checkCuda(cudaFree(gpu.labels));
	checkCuda(cudaFree(gpu.phi));
	checkCuda(cudaFree(gpu.phiOut));
	checkCuda(cudaFree(gpu.targetLabels));
	checkCuda(cudaFree(gpu.lowerIntensityBounds));
	checkCuda(cudaFree(gpu.upperIntensityBounds));
	checkCuda(cudaFree(gpu.globalBlockIndicator));
	checkCuda(cudaFree(gpu.globalFinishedVariable));
	
	#if defined(CUDA_TIMING)
		TIMER_END(Ttime);
		printf("Total GPU Execution Time: %f ms\n", Ttime);
	#endif
	
	#if defined(VERBOSE)
		for (int i = 0; i < numLabels; i++){
			printf("target label: %d converged in %d iterations.\n", 
					targetLabels[i],
					gpu.totalIterationsOnCpu[i]);	
		}
	#endif
	
	return(gpu.phiOnCpu);

}
