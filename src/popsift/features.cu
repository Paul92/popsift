/*
 * Copyright 2016-2017, Simula Research Laboratory
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#include <iomanip>
#include <stdio.h>
#include <iostream>
#include <unistd.h>
#ifndef __APPLE__
#include <malloc.h>
#endif
#include <stdlib.h>
#include <errno.h>
#include <math_constants.h>
#include "features.h"
#include "sift_extremum.h"
#include "common/debug_macros.h"
#include "sift_conf.h"
#include <thrust/sort.h>
#include <thrust/device_vector.h>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>

#include "lock.h"

using namespace std;

namespace popsift {
    

/*************************************************************
 * Features
 *************************************************************/

    Features::Features( )
	: _num_ext( 0 )
	, _num_ori( 0 )
    { }
    
    Features::~Features( )
    { }
    
/*************************************************************
 * HostFeatures
 *************************************************************/
    
    HostFeatures::HostFeatures( )
	: _ext( 0 )
	, _ori( 0 )
    { }

    HostFeatures::HostFeatures( int num_ext, int num_ori )
	: _ext( 0 )
	, _ori( 0 )
    {
	reset( num_ext, num_ori );
    }

    HostFeatures::~HostFeatures( )
    {
	free( _ext );
	free( _ori );
    }

#ifdef __APPLE__
    static void* memalign( size_t alignment, size_t size )
    {
	void* ret;
	int err = posix_memalign( &ret, alignment, size );
	if( err != 0 ) {
	    errno = err;
	    ret = 0;
	}
	return ret;
    }
#endif

    void HostFeatures::reset( int num_ext, int num_ori )
    {
	if( _ext != 0 ) { free( _ext ); _ext = 0; }
	if( _ori != 0 ) { free( _ori ); _ori = 0; }

	_ext = (Feature*)memalign( sysconf(_SC_PAGESIZE), num_ext * sizeof(Feature) );
	if( _ext == 0 ) {
	    cerr << __FILE__ << ":" << __LINE__ << " Runtime error:" << endl
		 << "    Failed to (re)allocate memory for downloading " << num_ext << " features" << endl;
	    if( errno == EINVAL ) cerr << "    Alignment is not a power of two." << endl;
	    if( errno == ENOMEM ) cerr << "    Not enough memory." << endl;
	    exit( -1 );
	}
	_ori = (Descriptor*)memalign( sysconf(_SC_PAGESIZE), num_ori * sizeof(Descriptor) );
	if( _ori == 0 ) {
	    cerr << __FILE__ << ":" << __LINE__ << " Runtime error:" << endl
		 << "    Failed to (re)allocate memory for downloading " << num_ori << " descriptors" << endl;
	    if( errno == EINVAL ) cerr << "    Alignment is not a power of two." << endl;
	    if( errno == ENOMEM ) cerr << "    Not enough memory." << endl;
	    exit( -1 );
	}

	setFeatureCount( num_ext );
	setDescriptorCount( num_ori );
    }

    void HostFeatures::pin( )
    {
	cudaError_t err;
	err = cudaHostRegister( _ext, getFeatureCount() * sizeof(Feature), 0 );
	if( err != cudaSuccess ) {
	    cerr << __FILE__ << ":" << __LINE__ << " Runtime warning:" << endl
		 << "    Failed to register feature memory in CUDA." << endl
		 << "    " << cudaGetErrorString(err) << endl;
	}
	err = cudaHostRegister( _ori, getDescriptorCount() * sizeof(Descriptor), 0 );
	if( err != cudaSuccess ) {
	    cerr << __FILE__ << ":" << __LINE__ << " Runtime warning:" << endl
		 << "    Failed to register descriptor memory in CUDA." << endl
		 << "    " << cudaGetErrorString(err) << endl;
	}
    }

    void HostFeatures::unpin( )
    {
	cudaHostUnregister( _ext );
	cudaHostUnregister( _ori );
    }

    void HostFeatures::print( std::ostream& ostr, bool write_as_uchar ) const
    {
	for( int i=0; i<size(); i++ ) {
	    _ext[i].print( ostr, write_as_uchar );
	}
    }

    std::ostream& operator<<( std::ostream& ostr, const HostFeatures& feature )
    {
	feature.print( ostr, false );
	return ostr;
    }

/*************************************************************
 * DeviceFeatures
 *************************************************************/

    DeviceFeatures::DeviceFeatures( )
	: _ext( 0 )
	, _ori( 0 )
	, _rev( 0 )
    { }

    DeviceFeatures::DeviceFeatures( int num_ext, int num_ori )
	: _ext( 0 )
	, _ori( 0 )
	, _rev( 0 )
    {
	reset( num_ext, num_ori );
    }

    DeviceFeatures::~DeviceFeatures( )
    {
	cudaFree( _ext );
	cudaFree( _ori );
	cudaFree( _rev );
    }

    void DeviceFeatures::reset( int num_ext, int num_ori )
    {
	if( _ext != 0 ) { cudaFree( _ext ); _ext = 0; }
	if( _ori != 0 ) { cudaFree( _ori ); _ori = 0; }
	if( _rev != 0 ) { cudaFree( _rev ); _rev = 0; }

	_ext = popsift::cuda::malloc_devT<Feature>   ( num_ext, __FILE__, __LINE__ );
	_ori = popsift::cuda::malloc_devT<Descriptor>( num_ori, __FILE__, __LINE__ );
	_rev = popsift::cuda::malloc_devT<int>       ( num_ori, __FILE__, __LINE__ );

	setFeatureCount( num_ext );
	setDescriptorCount( num_ori );
    }

    __device__ inline float
    l2_in_t0( const float4* lptr, const float4* rptr )
    {
	const float4  lval = lptr[threadIdx.x];
	const float4  rval = rptr[threadIdx.x];
	const float4  mval = make_float4( lval.x - rval.x,
					  lval.y - rval.y,
					  lval.z - rval.z,
					  lval.w - rval.w );
	float   res = mval.x * mval.x
	    + mval.y * mval.y
	    + mval.z * mval.z
	    + mval.w * mval.w;

	res += __shfl_down( res, 16 );
	res += __shfl_down( res,  8 );
	res += __shfl_down( res,  4 );
	res += __shfl_down( res,  2 );
	res += __shfl_down( res,  1 );

	return res;
    }
    __device__ inline float
    dot_l2_in_t0( const float4* lptr, const float4* rptr )
    {
	const float4  lval = lptr[threadIdx.x];
	const float4  rval = rptr[threadIdx.x];
	const float4  mval = make_float4( lval.x * rval.x,
					  lval.y * rval.y,
					  lval.z * rval.z,
					  lval.w * rval.w );
	float   res = mval.x
	    + mval.y
	    + mval.z
	    + mval.w;

    
	res += __shfl_down( res, 16 );
	res += __shfl_down( res,  8 );
	res += __shfl_down( res,  4 );
	res += __shfl_down( res,  2 );
	res += __shfl_down( res,  1 );
	return res;
    }
  
    __global__ void
    compute_distance_l2( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len )
    {
	if( blockIdx.x >= l_len ) return;
	const int idx = blockIdx.x;

	float match_1st_val = CUDART_INF_F;
	float match_2nd_val = CUDART_INF_F;
	int   match_1st_idx = 0;
	int   match_2nd_idx = 0;

	const float4* lptr = (const float4*)( &l[idx] );

	for( int i=0; i<r_len; i++ )
	{
	    const float4* rptr = (const float4*)( &r[i] );

	    const float   res  = l2_in_t0( lptr, rptr );

	    if( threadIdx.x == 0 )
	    {
		if( res < match_1st_val )
		{
		    match_2nd_val = match_1st_val;
		    match_2nd_idx = match_1st_idx;
		    match_1st_val = res;
		    match_1st_idx = i;
		}
		else if( res < match_2nd_val )
		{
		    match_2nd_val = res;
		    match_2nd_idx = i;
		}
	    }
	    __syncthreads();
	}

	if( threadIdx.x == 0 )
	{
	    bool accept = ( match_1st_val / match_2nd_val < 0.8f );
	    match_matrix[blockIdx.x] = make_int3( match_1st_idx, match_2nd_idx, accept );
	}
    }


    __global__ void
    compute_distance_dot_256( int3* match_matrix, const Descriptor* l, const int l_len, const Descriptor* r, const int r_len )
    {
	const int idx = threadIdx.y + blockIdx.x * 2;
	if ( idx >= l_len ) return;

	float match_1st_val = -1.0f;
	float match_2nd_val = -1.0f;
	int   match_1st_idx = 0;
	int   match_2nd_idx = 0;

  

	const float4* lptr = (const float4*)( &l[idx] );

	for( int i=0; i<r_len; i++ )
	{
	    const float4* rptr = (const float4*)( &r[i] );
	    const float   res  = dot_l2_in_t0( lptr, rptr );

	
	    if( threadIdx.x == 0 )
	    {
		if( res > match_1st_val )
		{
		    match_2nd_val = match_1st_val;
		    match_2nd_idx = match_1st_idx;
		    match_1st_val = res;
		    match_1st_idx = i;
		}
		else if( res > match_2nd_val )
		{
		    match_2nd_val = res;
		    match_2nd_idx = i;
		}
	    }

	    __syncthreads();	
	}
    
	
	const int one = __shfl(match_1st_idx, 0);
	const int two = __shfl(match_2nd_idx, 0);
  
	const float4* rptr = (const float4*)( &r[one] );
	const float res2 = l2_in_t0( lptr, rptr );
	const float4* rptr2 = (const float4*)( &r[two] );
	const float res3 = l2_in_t0( lptr, rptr2 );
	
	

	if( threadIdx.x == 0 )
	{
	    const bool accept = (res2/res3 < 0.8f );
	    match_matrix[idx] = make_int3( match_1st_idx, match_2nd_idx, accept );
	}
    }

    
  
    __global__ void
    compute_distance_dot( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len )
    {
	if( blockIdx.x >= l_len ) return;
	const int idx = blockIdx.x;

	float match_1st_val = -1.0f;
	float match_2nd_val = -1.0f;
	int   match_1st_idx = 0;
	int   match_2nd_idx = 0;

  

	const float4* lptr = (const float4*)( &l[idx] );

	for( int i=0; i<r_len; i++ )
	{
	    const float4* rptr = (const float4*)( &r[i] );
	    const float   res  = dot_l2_in_t0( lptr, rptr );

	
	    if( threadIdx.x == 0 )
	    {
		if( res > match_1st_val )
		{
		    match_2nd_val = match_1st_val;
		    match_2nd_idx = match_1st_idx;
		    match_1st_val = res;
		    match_1st_idx = i;
		}
		else if( res > match_2nd_val )
		{
		    match_2nd_val = res;
		    match_2nd_idx = i;
		}
	    }

	    __syncthreads();	
	}
    
    
	const int one = __shfl(match_1st_idx, 0);
	const int two = __shfl(match_2nd_idx, 0);
  
	const float4* rptr = (const float4*)( &r[one] );
	const float res2 = l2_in_t0( lptr, rptr );
	const float4* rptr2 = (const float4*)( &r[two] );
	const float res3 = l2_in_t0( lptr, rptr2 );

	if( threadIdx.x == 0 )
	{
	    bool accept = (res2/res3 < 0.8f );
	    match_matrix[blockIdx.x] = make_int3( match_1st_idx, match_2nd_idx, accept );
	}
    }


        __global__ void
	compute_dot_no_sync( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len, float *norm )
    {
	float match_1st_val = -1.0f;
	float match_2nd_val = -1.0f;
	int   match_1st_idx = 0;
	int   match_2nd_idx = 0;
	int j;
	
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	float *res = norm + tid * r_len;

	const float* lptr = (const float *)( &l[tid] );

	for( int i=0; i<r_len; i++ )
	{

	    const float *rptr = (const float *)( &r[i] );
	    res[i] = 0.0f;
	    
	    for (j = 0; j < 128; j++)
	    {
		res[i] += lptr[j] * rptr[j];
	    }
	}
    }


    
    __global__ void
    compute_dot_in_section( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len, thrust::device_ptr<int> indexes, unsigned int *start_idx, unsigned int *stop_idx )
    {
	
	if( blockIdx.x >= l_len ) return; 
	const int idx = blockIdx.x;
	
	float match_1st_val = -1.0f;
	float match_2nd_val = -1.0f;
	int   match_1st_idx = 0;
	int   match_2nd_idx = 0;

  

	const float4* lptr = (const float4*)( &l[idx] );

	for( int i = start_idx[idx]; i< stop_idx[idx]; i++ )
	{
	    const float4* rptr = (const float4*)( &r[indexes[i]] );
	    const float   res  = dot_l2_in_t0( lptr, rptr );

	
	    if( threadIdx.x == 0 )
	    {
		if( res > match_1st_val )
		{
		    match_2nd_val = match_1st_val;
		    match_2nd_idx = match_1st_idx;
		    match_1st_val = res;
		    match_1st_idx = i;
		}
		else if( res > match_2nd_val )
		{
		    match_2nd_val = res;
		    match_2nd_idx = i;
		}
	    }

	    __syncthreads();	
	}
    
    
	const int one = __shfl(match_1st_idx, 0);
	const int two = __shfl(match_2nd_idx, 0);
  
	const float4* rptr = (const float4*)( &r[indexes[one]] );
	const float res2 = l2_in_t0( lptr, rptr );
	const float4* rptr2 = (const float4*)( &r[indexes[two]] );
	const float res3 = l2_in_t0( lptr, rptr2 );

	if( threadIdx.x == 0 )
	{
	    bool accept = (res2/res3 < 0.8f );
	    match_matrix[blockIdx.x] = make_int3( indexes[match_1st_idx], indexes[match_2nd_idx], accept );
	}
    }


   __global__ void
    compute_dot_sorted_section( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len, unsigned int *start_idx, unsigned int *stop_idx )
    {
	
	if( blockIdx.x >= l_len ) return; //redundant?
	const int idx = blockIdx.x;
	
	float match_1st_val = -1.0f;
	float match_2nd_val = -1.0f;
	int   match_1st_idx = 0;
	int   match_2nd_idx = 0;

  

	const float4* lptr = (const float4*)( &l[idx] );

	for( int i = start_idx[idx]; i< stop_idx[idx]; i++ )
	{
	    const float4* rptr = (const float4*)( &r[i] );
	    const float   res  = dot_l2_in_t0( lptr, rptr );

	
	    if( threadIdx.x == 0 )
	    {
		if( res > match_1st_val )
		{
		    match_2nd_val = match_1st_val;
		    match_2nd_idx = match_1st_idx;
		    match_1st_val = res;
		    match_1st_idx = i;
		}
		else if( res > match_2nd_val )
		{
		    match_2nd_val = res;
		    match_2nd_idx = i;
		}
	    }

	    __syncthreads();	
	}
    
    
	const int one = __shfl(match_1st_idx, 0);
	const int two = __shfl(match_2nd_idx, 0);
  
	const float4* rptr = (const float4*)( &r[one] );
	const float res2 = l2_in_t0( lptr, rptr );
	const float4* rptr2 = (const float4*)( &r[two] );
	const float res3 = l2_in_t0( lptr, rptr2 );

	if( threadIdx.x == 0 )
	{
	    bool accept = (res2/res3 < 0.8f );
	    match_matrix[blockIdx.x] = make_int3( match_1st_idx, match_2nd_idx, accept );
	}
    }

 __global__ void
    compute_dot_sorted_section_org( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len, unsigned int *start_idx, unsigned int *stop_idx )
    {
	
	if( blockIdx.x >= l_len ) return; //redundant?
	const int idx = blockIdx.x;
	
	float match_1st_val = -1.0f;
	float match_2nd_val = -1.0f;
	int   match_1st_idx = 0;
	int   match_2nd_idx = 0;

	int begin = start_idx[idx];
	int end = stop_idx[idx];

	const float4* lptr = (const float4*)( &l[idx] );
	
	for( int i = begin; i < end; i++ )
	{
	    const float4* rptr = (const float4*)( &r[i] );
	    const float   res  = dot_l2_in_t0( lptr, rptr );

	
	    if( threadIdx.x == 0 )
	    {
		if( res > match_1st_val )
		{
		    match_2nd_val = match_1st_val;
		    match_2nd_idx = match_1st_idx;
		    match_1st_val = res;
		    match_1st_idx = i;
		}
		else if( res > match_2nd_val )
		{
		    match_2nd_val = res;
		    match_2nd_idx = i;
		}
	    }

	    __syncthreads();	
	}
    
    
	const int one = __shfl(match_1st_idx, 0);
	const int two = __shfl(match_2nd_idx, 0);
  
	const float4* rptr = (const float4*)( &r[one] );
	const float res2 = l2_in_t0( lptr, rptr );
	const float4* rptr2 = (const float4*)( &r[two] );
	const float res3 = l2_in_t0( lptr, rptr2 );

	if( threadIdx.x == 0 )
	{
	    bool accept = (res2/res3 < 0.8f );
	    match_matrix[blockIdx.x] = make_int3( match_1st_idx, match_2nd_idx, accept );
	}
    }

    
    
    #define DESC_SEQ 4
    struct Desc 
    {
	float descriptor[DESC_SEQ]; //float makes a difference?
    };

    
    __device__
    unsigned int hamming_distance(unsigned int* A, unsigned int* B) //make const?
    {
	unsigned int g[4];
	unsigned int sum, sum_1, sum_2;

	g[0] = *A ^ *B;
	g[1] = *(A + 4) ^ *(B + 4);
	g[2] = *(A + 8) ^ *(B + 8);
	g[3] = *(A + 12) ^ *(B + 12);

	sum_1 = __popc(*g);
	sum_2 = __popc(*(g + 1));
	sum_1 += __popc(*(g + 2));
	sum_2 += __popc(*(g + 3));
	sum = sum_1 + sum_2;
	return sum;
    }

    __global__ void
    compute_distance_hamming( int3* match_matrix, Descriptor* l, Descriptor* l_tra, int l_len, Descriptor* r, Descriptor* r_tra, int r_len, thrust::device_ptr<int> indexes, unsigned int *start_idx, unsigned int *stop_idx )
    {

	int stride = blockDim.x * gridDim.x;
	
	const int idx = blockIdx.x;
        int offset = 2;

        
        int match_1st_val = 128;
	int match_2nd_val = 128;
	int match_1st_idx = 0;
	int match_2nd_idx = 0;

	if (start_idx[idx] == 0) offset = 3;
	__syncthreads; //remove?


	int begin = start_idx[idx];
	int end = stop_idx[idx];

        struct Desc *lptr = (struct Desc *)((&l_tra[idx])) + offset;

	    
	for( int i = begin; i < end; i++ )
	{
	    //const float4* rptr = (const float4*)( &r_[indexes[i]] );
	    const struct Desc *rptr = (struct Desc *)((&r_tra[idx])) + offset;

		
	    //const float   res  = dot_l2_in_t0( lptr, rptr );
	    const int res = hamming_distance((unsigned int *)lptr, (unsigned int *)rptr);
	
	    if( threadIdx.x == 0 )
	    {
		if( res < match_1st_val )
		{
		    match_2nd_val = match_1st_val;
		    match_2nd_idx = match_1st_idx;
		    match_1st_val = res;
		    match_1st_idx = i;
		}
		else if( res < match_2nd_val )
		{
		    match_2nd_val = res;
		    match_2nd_idx = i;
		}
	    }

	    __syncthreads();	
	}

	const int one = __shfl(match_1st_idx, 0);
	const int two = __shfl(match_2nd_idx, 0);


	float result_1 = 0.0f;
	float result_2 = 0.0f;
	//float diff0, diff1, diff2, diff3;
	float diff0 = 0.0f, diff1 = 0.0f, diff2 = 0.0f, diff3 = 0.0f;


	int i = 0;
	int last = 127 - 3;

	// Process 4 items with each loop for efficiency. helps on gpu at all?
	while (i < last) {
	    diff0 = l[indexes[idx]].features[i] - r[indexes[one]].features[i];
	    diff1 = l[indexes[idx]].features[i+1] - r[indexes[one]].features[i+1];
	    diff2 = l[indexes[idx]].features[i+2] - r[indexes[one]].features[i+2];
	    diff3 = l[indexes[idx]].features[i+3] - r[indexes[one]].features[i+3];
	    result_1 += diff0 * diff0 + diff1 * diff1 + diff2 * diff2 + diff3 * diff3;
	    i += 4;
	}

	i = 0;

	while (i < last) {
	    diff0 = l[indexes[idx]].features[i] - r[indexes[two]].features[i];
	    diff1 = l[indexes[idx]].features[i+1] - r[indexes[two]].features[i+1];
	    diff2 = l[indexes[idx]].features[i+2] - r[indexes[two]].features[i+2];
	    diff3 = l[indexes[idx]].features[i+3] - r[indexes[two]].features[i+3];
	    result_2 += diff0 * diff0 + diff1 * diff1 + diff2 * diff2 + diff3 * diff3;
	    i += 4;
	}
		
	if( threadIdx.x == 0 )
	{
	    bool accept = (result_1/result_2 < 0.8f );
	    match_matrix[blockIdx.x] = make_int3( indexes[match_1st_idx], indexes[match_2nd_idx], accept );
	}
	
	// idx += stride;
	//}
    }


     __global__ void
    compute_distance_hamming_levels( int3* match_matrix, Descriptor* l, Descriptor* l_tra, int l_len, Descriptor* r, Descriptor* r_tra, int r_len, thrust::device_ptr<int> indexes, unsigned int *start_idx, unsigned int *stop_idx )
    {
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	int stride = blockDim.x * gridDim.x;
	
	const int idx = blockIdx.x;
        int offset = 2;
	
	//float match_1st_val = -1.0f;
	//float match_2nd_val = -1.0f;

        int match_1st_val_1 = 128;
	int match_2nd_val_1 = 128;
	int match_1st_val_2 = 128;
	int match_2nd_val_2 = 128;
	int match_1st_val_3 = 128;
	int match_2nd_val_3 = 128;
	int match_1st_val_4 = 128;
	int match_2nd_val_4 = 128;


	int match_1st_idx = 0;
	int match_2nd_idx = 0;

	
	if (start_idx[idx] == 0) offset = 3;
	__syncthreads;
	
        struct Desc *lptr_1 = (struct Desc *)((&l_tra[indexes[idx]])) + offset;
	struct Desc *lptr_2 = (struct Desc *)((&l_tra[indexes[idx]])) + offset + 1;
        struct Desc *lptr_3 = (struct Desc *)((&l_tra[indexes[idx]])) + offset + 2;
	struct Desc *lptr_4 = (struct Desc *)((&l_tra[indexes[idx]])) + offset + 3;

			

	for( int i = start_idx[idx]; i< stop_idx[idx]; i++ )
	{
	    //const float4* rptr = (const float4*)( &r_[indexes[i]] );
	    const struct Desc *rptr_1 = (struct Desc *)((&r_tra[indexes[idx]])) + offset;
	    const struct Desc *rptr_2 = (struct Desc *)((&r_tra[indexes[idx]])) + offset + 1;
	    const struct Desc *rptr_3 = (struct Desc *)((&r_tra[indexes[idx]])) + offset + 2;
	    const struct Desc *rptr_4 = (struct Desc *)((&r_tra[indexes[idx]])) + offset + 3;

		
	    //const float   res  = dot_l2_in_t0( lptr, rptr );
	    const int res_1 = hamming_distance((unsigned int *)lptr_1, (unsigned int *)rptr_1);
	    const int res_2 = hamming_distance((unsigned int *)lptr_2, (unsigned int *)rptr_2);
	    const int res_3 = hamming_distance((unsigned int *)lptr_3, (unsigned int *)rptr_3);
	    const int res_4 = hamming_distance((unsigned int *)lptr_4, (unsigned int *)rptr_4);

	    if( threadIdx.x == 0 ) 
	    {
		
		int not_best = 1;
		if ( res_1 < match_1st_val_1 ) // first level shorter distance
		{
		    match_2nd_val_1 = match_1st_val_1;
		    match_2nd_val_2 = match_1st_val_2;
		    match_2nd_val_3 = match_1st_val_3;
		    match_2nd_val_4 = match_1st_val_4;

		    match_2nd_idx = match_1st_idx;
		    match_1st_idx = i;

		    match_1st_val_1 = res_1;
		    match_1st_val_2 = res_2;
		    match_1st_val_3 = res_3;
		    match_1st_val_4 = res_4;
		    not_best = 0;

		}
		else if ( res_1 == match_1st_val_1 ) // first level equal distance
		{
		    if ( res_2 < match_1st_val_2 ) // second level shorter distance
		    {
			match_2nd_val_1 = match_1st_val_1;
			match_2nd_val_2 = match_1st_val_2;
			match_2nd_val_3 = match_1st_val_3;
			match_2nd_val_4 = match_1st_val_4;
			
			match_2nd_idx = match_1st_idx;
			match_1st_idx = i;
			
			match_1st_val_1 = res_1; //since equal, not nessesary.. other places as well
			match_1st_val_2 = res_2;
			match_1st_val_3 = res_3;
			match_1st_val_4 = res_4;
		        not_best = 0;
			printf("res1: %d\t res2 %d\n", res_1, res_2);
					    
		    }
		    else if ( res_2 == match_1st_val_2 ) // second level equal distance
		    {
			if ( res_3 < match_1st_val_3 ) // third level shorter distance
			{
			    match_2nd_val_1 = match_1st_val_1; 
			    match_2nd_val_2 = match_1st_val_2; 
			    match_2nd_val_3 = match_1st_val_3;
			    match_2nd_val_4 = match_1st_val_4;
			
			    match_2nd_idx = match_1st_idx;
			    match_1st_idx = i;
			
			    match_1st_val_1 = res_1; //equal
			    match_1st_val_2 = res_2; //equal
			    match_1st_val_3 = res_3;
			    match_1st_val_4 = res_4;
			    not_best = 0;
			}
			else if ( res_3 == match_1st_val_3 ) //skip equal, go directly on next if statement?
			{
			    if ( res_4 < match_1st_val_4 ) // forth level shorter distance
			    {
				match_2nd_val_1 = match_1st_val_1; 
				match_2nd_val_2 = match_1st_val_2; 
				match_2nd_val_3 = match_1st_val_3;
				match_2nd_val_4 = match_1st_val_4;
			
				match_2nd_idx = match_1st_idx;
				match_1st_idx = i;
			
				match_1st_val_1 = res_1; //equal
				match_1st_val_2 = res_2; //equal
				match_1st_val_3 = res_3; //equal
				match_1st_val_4 = res_4;
			        not_best = 0;
			    }
			}
		    }
		}
		else if ( not_best == 1 ) // could find a better way to do this i think.. check for 0 instead? set 1 in an else maybe?
		{
		    if ( res_1 < match_2nd_val_1 )
		    {
			match_2nd_val_1 = res_1;
			match_2nd_val_2 = res_2;
			match_2nd_val_3 = res_3;
			match_2nd_val_4 = res_4;
			match_2nd_idx = i;
		    }
		    else if ( res_1 == match_2nd_val_1)
		    {
			if ( res_2 < match_2nd_val_2 )
			{
			    match_2nd_val_1 = res_1; //equal
			    match_2nd_val_2 = res_2;
			    match_2nd_val_3 = res_3;
			    match_2nd_val_4 = res_4;
			    match_2nd_idx = i;
			}
			else if ( res_2 == match_2nd_val_2)
			{
			    if ( res_3 < match_2nd_val_3 )
			    {
				match_2nd_val_1 = res_1; //equal
				match_2nd_val_2 = res_2; //equal
				match_2nd_val_3 = res_3;
				match_2nd_val_4 = res_4;
				match_2nd_idx = i;
			    }
			    else if ( res_3 == match_2nd_val_3)
			    {
				if ( res_4 < match_2nd_val_4 )
				{
				    match_2nd_val_1 = res_1; //equal
				    match_2nd_val_2 = res_2; //equal
				    match_2nd_val_3 = res_3; //equal
				    match_2nd_val_4 = res_4;
				    match_2nd_idx = i;
				}
			    }
			}
		    }
		}
	    }

	    __syncthreads();	
	}

	const int one = __shfl(match_1st_idx, 0);
	const int two = __shfl(match_2nd_idx, 0);


	float result_1 = 0.0f;
	float result_2 = 0.0f;
	//float diff0, diff1, diff2, diff3;
	float diff0 = 0.0f, diff1 = 0.0f, diff2 = 0.0f, diff3 = 0.0f;


	int i = 0;
	int last = 127 - 3;

	// Process 4 items with each loop for efficiency. helps on gpu at all?
	while (i < last) {
	    diff0 = l[indexes[idx]].features[i] - r[indexes[one]].features[i];
	    diff1 = l[indexes[idx]].features[i+1] - r[indexes[one]].features[i+1];
	    diff2 = l[indexes[idx]].features[i+2] - r[indexes[one]].features[i+2];
	    diff3 = l[indexes[idx]].features[i+3] - r[indexes[one]].features[i+3];
	    result_1 += diff0 * diff0 + diff1 * diff1 + diff2 * diff2 + diff3 * diff3;
	    i += 4;
	}

	i = 0;

	while (i < last) {
	    diff0 = l[indexes[idx]].features[i] - r[indexes[two]].features[i];
	    diff1 = l[indexes[idx]].features[i+1] - r[indexes[two]].features[i+1];
	    diff2 = l[indexes[idx]].features[i+2] - r[indexes[two]].features[i+2];
	    diff3 = l[indexes[idx]].features[i+3] - r[indexes[two]].features[i+3];
	    result_2 += diff0 * diff0 + diff1 * diff1 + diff2 * diff2 + diff3 * diff3;
	    i += 4;
	}
		
	if( threadIdx.x == 0 )
	{
	    bool accept = (result_1/result_2 < 0.8f );
	    match_matrix[blockIdx.x] = make_int3( indexes[match_1st_idx], indexes[match_2nd_idx], accept );
	}
	
	// tid += stride;
	//}
    }


    __host__ __device__ void
    printBits( unsigned int num )
    {
        for ( int bit = 0; bit < 32; bit++ )
	{
	    printf("%i", num & 0x01);
	    num = num >> 1;
	}
    }

  
    __host__ __device__ void
    printFeature( unsigned int *num )
    {
        for ( int i = 0; i < 128; i += 4 ) {
            for (int j = 0; j < 4; j++) {
		printBits(num[ i + j]);
		printf( " " );
            }
            
            printf( "\n" ); 
        }
        
	printf( "\n\n" );
    }

    __device__ void
    print32x32( unsigned int *num )
    {
        for ( int i = 0; i < 32; i++ ) {
            printBits(num[i]);
            printf( "\n" ); 
        }
        
        printf( "\n\n" );
    }



/*****************************
HASH TABLE - fix seperate file.
******************************/
    

#define HASH_ENTRIES     1024 //increase
    struct Entry;
    struct Inner_Table;
    
/*
 * struct: Inner_Table
 * -------------------
 * Hash table within each entry of main hash table
 * 
 * Count: Number of entries in our table.
 * Entries: List of entries. Each address 
 * here is a pointer to an entry. 
 */
    struct Inner_Table
    {
	size_t count;
	Entry **entries;
    };

    
/*
 * struct: Entry
 * --------------
 * Table entry for hash table
 * 
 * Each entry holds: 
 * Key: a 128 bit significanse sequence of a discriptor, 
 * Value: an interval of indexes desided by begin and end
 * Next: Null or pointer to the next entry within this 'bucket'. 
 */
    struct Entry
    {
	struct Desc key;
	unsigned int begin;
	unsigned int end;
	Inner_Table next_table;
	Entry *next = NULL;
	
    };


    
/*
 * struct: Table
 * --------------
 * Hash table
 * 
 * Count: Number of entries in our table.
 * Entries: List of entries. Each address 
 * here is a pointer to an entry. 
 * Pool: Unused entries. Pre allocated.
 * Entries for inner table is also supplied from pool.
 */
    struct Table
    {
	size_t count;
	Entry   **entries;
	Entry   *pool;
	
    };

    


    

    struct bloom_filter 
    {
	uint8_t *bits;
	size_t size;
    };


    __host__ __device__
    unsigned int djb2(const void *_str)
    {
	const char *str = (const char *)_str;
	unsigned int hash = 5381;
	char c, i = 0;
	while ((i < 16))
	{
	    c = str[i];
	    hash = ((hash << 5) + hash) + c;
	    i++;
	}
	return hash;
    }

    __host__ __device__
    unsigned int jenkins(const void *_str)
    {
	const char *key = (const char *)_str;
	unsigned int hash, i = 0;
	while (i < 16)
	{
	    hash += *key;
	    hash += (hash << 10);
	    hash ^= (hash >> 6);
	    key++;
	    i++;
	}
	hash += (hash << 3);
	hash ^= (hash >> 11);
	hash += (hash << 15);
	return hash;
    }
    
/*
 * Could create a function pointer in the table, and pass different hash 
 * functions for a better testing environment 
 */
    __device__ __host__
    size_t hash(unsigned int * key, size_t count )
    {
	int i = 0;
	size_t sum = 0;
	unsigned char * p  = (unsigned char *)key;

	while (i < 16)
	{
	    sum += p[i];
	    sum += (sum << 10);
	    sum ^= (sum >> 6);
	    i++;
	}

	sum += (sum << 3);
	sum ^= (sum >> 11);
	sum += (sum << 15);

	return sum % count;
    }

    __device__ __host__
    size_t hash2(unsigned int * key, size_t count )
    {
	int i = 0;
	char c;
	size_t sum = 5381;
	unsigned char * p  = (unsigned char *)key;

	while (i < 16)
	{
	    c = p[i];
	    sum = ((sum << 5) + sum) + c;
	    i++;
	}

	return sum % count;
    }


    void initialize_table( Table &table, int entries, int elements ) //elements should be 2 times descriptors
    {
	//printf("init: entries: %d\t elements: %d\n", entries, elements);
	table.count = entries;
	cudaMalloc( (void**)&table.entries, entries * sizeof(Entry*) );
	cudaMemset( table.entries, 0, entries * sizeof(Entry*) );
	cudaMalloc( (void**)&table.pool, elements * sizeof(Entry) ); 
	
	//allocate all the entries we need
	Entry ** alloc_entries;
	cudaMalloc((void**)&alloc_entries, entries * entries * sizeof(Entry*));
	Entry **itr = alloc_entries;

	
	Entry *tmp = (Entry *)malloc(elements * sizeof(Entry));	
	for (int i = 0; i < entries; i++)
	{
	    tmp[i].next_table.entries = itr;
	    itr += entries;
	}

	cudaMemcpy(table.pool, tmp, elements * sizeof(Entry), cudaMemcpyHostToDevice);
	
    }



    void initialize_table_async( Table &table, int entries, int elements ) //elements should be 2 times descriptors
    {
	//printf("init: entries: %d\t elements: %d\n", entries, elements);
	table.count = entries;
	cudaMalloc( (void**)&table.entries, entries * sizeof(Entry*) );
	cudaMemsetAsync( table.entries, 0, entries * sizeof(Entry*) );
	cudaMalloc( (void**)&table.pool, elements * sizeof(Entry) ); 


	/*
	//allocate all the entries we need
	Entry ** alloc_entries;
	cudaMalloc((void**)&alloc_entries, entries * entries * sizeof(Entry*));
	Entry **itr = alloc_entries;


	//Entry *alloc_entries = (Entry*)malloc(entries * entries * sizeof(Entry));
	
	Entry *tmp = (Entry *)malloc(elements * sizeof(Entry));	
	for (int i = 0; i < entries; i++)
	{
	    tmp[i].next_table.entries = itr;
	    itr += entries;
	}

	cudaMemcpy(table.pool, tmp, elements * sizeof(Entry), cudaMemcpyHostToDevice);
	*/
    }

    void free_table( Table &table )
    {
	cudaFree( table.pool );
	cudaFree( table.entries );
    }



    void copy_table_to_host( const Table &table, Table &hostTable, unsigned int elements )
    {
	hostTable.count = table.count;
	hostTable.entries = (Entry**)calloc( table.count, sizeof(Entry*) );
	hostTable.pool = (Entry*)malloc( elements * sizeof( Entry ) );
    
	cudaMemcpy( hostTable.entries, table.entries, table.count * sizeof(Entry*), cudaMemcpyDeviceToHost );
	cudaMemcpy( hostTable.pool, table.pool, elements * sizeof( Entry ), cudaMemcpyDeviceToHost );

    
	for (int i=0; i<table.count; i++)
	{
	    if (hostTable.entries[i] != NULL)
		hostTable.entries[i] = (Entry*)((size_t)hostTable.entries[i] - (size_t)table.pool + (size_t)hostTable.pool);
	}
    

	for ( int i=0; i < elements; i++)
	{
	    if (hostTable.pool[i].next != NULL)
		hostTable.pool[i].next = (Entry*)((size_t)hostTable.pool[i].next - (size_t)table.pool + (size_t)hostTable.pool);
	}

    }

    void verify_table( const Table &dev_table, unsigned int elements )
    {
	Table table;
	copy_table_to_host( dev_table, table, elements );
	int count = 0;


	for (size_t i=0; i<table.count; i++)
	{
	    Entry   *current = table.entries[i];
	    while (current != NULL)
	    {
		if (current->end - current->begin > 1)
		    printf("begin %d\t end %d\t table %d\n",  current->begin, current->end, i);
		++count;
		if (hash((unsigned int *)&(current->key), table.count ) != i)
		    printf("begin %d end %d hashed to %ld, but was located "
			   "at %ld\n",
			   current->begin, current->end,
			   hash((unsigned int *)&(current->key), table.count), i ); // *(unsigned int *)*/
		current = current->next;

	    }
	}

	if (count != elements)
	    printf( "%d elements found in hash table.  Should be %d\t missing are likely ignored duplicates\n", count, elements );
	else
	    printf( "All %d elements found in hash table.\n", count );
	free( table.pool );
	free( table.entries ); 
    }
    
    __device__ 
    int compareKey(unsigned char *A, unsigned char *B)
    {
	int i = 0;
	while ( i < DESC_SEQ * DESC_SEQ && A[i] == B[i] ) i++;
	if (i == 16) return -1;
	return 1;
    }

    __device__
    unsigned int bloom_check( uint8_t * bits,  struct Desc *key, unsigned int size) 
    {
	const unsigned int hashkey_1 = hash((unsigned int *)key, size);
	if (bits[hashkey_1] != 1) return 0;
	const unsigned int hashkey_2 = hash2((unsigned int *)key, size);
	if (bits[hashkey_2] != 1) return 0;
	return 1;
    }


    //might be possible to do this in some sort of log n format due to sorted keys
    __global__ void
    add_to_table( struct Descriptor *keys, thrust::device_ptr<int> values, Table table, Lock *lock, unsigned int elements)
    {
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	int stride = blockDim.x * gridDim.x;
	while (tid < elements)
	{
	    
	    //cast so we only use first 16bytes, we use the indirect lookup sorted list to find
	    //corresponding key value pair... skip first two layers as they are both zero.
	    
	    struct Desc *key = (struct Desc *)((&keys[values[tid]])) + 2;
	    //struct Desc *key2 = (struct Desc *)((&keys[values[tid]])) + 3;

	    size_t hashValue = hash((unsigned int *)key, table.count );
	    //size_t hashValue2 = hash((unsigned int *)key2, table.count );

	    for (int i=0; i<32; i++)
	    {
		if ((tid % 32) == i)
		{
		    Entry *location = &(table.pool[tid]);
		    memcpy(&(location->key), key, sizeof(struct Desc));
		    //location->value = values[tid];
		    location->begin = tid; //values[tid]?
		    location->end = tid + 1;

		    /* second layer
		    Entry *location2 = &(table.pool[tid + (elements / 2)]);
		    memcpy(&(location2->key), key2, sizeof(struct Desc));
		    location2->begin = tid; //values[tid]?
		    location2->end = tid + 1;
		    */

		    lock[hashValue].lock();

		    Entry *ptr = table.entries[hashValue];
		    int exists = 1;
		    while (ptr != NULL)
		    {
			//exists = compareKey((unsigned int *)&(ptr->key), (unsigned int *)&(location->key)); //pretty sure this does not work as intended..
			exists = compareKey((unsigned char *)&(ptr->key), (unsigned char *)&(location->key));
			if (exists == -1) break;
			ptr = ptr->next;
		    }
		
		    if (exists == 1)
		    {
			//set up second layer first
			//location2->next = location->next_table.entries[hashValue2];
			//location->next_table.entries[0] = location2;

			//Inner_Table it  = location->next_table; //should be ptr?
			//	it.entries[1] = NULL;
			//add entry to table
			location->next = table.entries[hashValue];
			table.entries[hashValue] = location;


		    }
		    else
		    {
			if (location->begin < ptr->begin) ptr->begin = location->begin;
			if (location->end > ptr->end) ptr->end = location->end;
		    }
		
		    lock[hashValue].unlock();
		}
	    }
	
	    tid += stride;
	} 
    }



    __global__ void
    get_section_from_table( Table table, struct Descriptor *keys, unsigned int elements, unsigned int l_len, unsigned int *start_idx, unsigned int *stop_idx )
    {
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	int stride = blockDim.x * gridDim.x;
	int check;
	//Search area - set to max if no key match is found
	
	while (tid < elements)
	{
	    struct Desc *key = (struct Desc *)(&keys[tid]) + 2; //+2 because second layer is currently stored.
	    size_t hashValue = hash((unsigned int *)key, table.count );
	    Entry *ptr = table.entries[hashValue];
	    int exists = 1;
	    int cnt = 0;

	    while (ptr != NULL)
	    {
		exists = compareKey((unsigned char *)&(ptr->key), (unsigned char *)key);
		if (exists == -1) break;
		ptr = ptr->next;
	    }

	    if (exists == -1 && (ptr->end - ptr->begin) > 1) //must be two or more in set
	    {
		start_idx[tid] = ptr->begin;
		stop_idx[tid] = ptr->end;
	    }
	    else
	    {
		start_idx[tid] = 0;
		stop_idx[tid] = l_len;

	    }
	
	    tid += stride;
	}
    }

/********************************
HASH TABLE END - fix seperate file.
**********************************/




/*****************************
BLOOM FILTER
****************************/



    void initialize_bloom_filter( bloom_filter &bloom, size_t size )
    {
	bloom.size = size;
	cudaMalloc( (void**)&bloom.bits, size );
	cudaMemset( bloom.bits, 0, size ); 
    }



//bytewise bloomfilter
    __device__
    void bloom_add( bloom_filter &filter, const void *item ) 
    {
	uint8_t *bits = (uint8_t *)filter.bits;

	unsigned int hash = jenkins(item);
	printf("hash: %d\n", hash);
	hash %= filter.size;
	printf("hash MOD: %d\n", hash);
	bits[hash] = 1;
	printf("hash/8: %d\n", hash);

	hash = djb2(item);
    }



    __global__ void
    bloom_add_filters( bloom_filter bloom,  struct Descriptor *keys, unsigned int elements)
    {
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	int stride = blockDim.x * gridDim.x;

	uint8_t *bits = (uint8_t *)bloom.bits;
	unsigned int hashkey;
	struct Desc *key;
	while (tid < elements)
	{
	    key = (struct Desc *)((&keys[tid])) + 2;
	    hashkey = hash((unsigned int *)key, bloom.size);
	    bits[hashkey] = 1;
	    hashkey = hash2((unsigned int *)key, bloom.size);
	    bits[hashkey] = 1;
	    tid += stride;
	}
    }

    //even if hit we do not know if we have  two or more in the set... pointless?
    //cant see imediate benefit.
    __global__ void
    bloom_filter_check( bloom_filter bloom,  struct Descriptor *keys, unsigned int elements)
    {
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	int stride = blockDim.x * gridDim.x;

	uint8_t *bits = (uint8_t *)bloom.bits;
	unsigned int hashkey_1;
	unsigned int hashkey_2;

	int check = 1;
	struct Desc *key;
	while (tid < elements)
	{
	    key = (struct Desc *)((&keys[tid])) + 2;
	    hashkey_1 = hash((unsigned int *)key, bloom.size);
	    if (bits[hashkey_1] != 1)
		check = 0;
	    hashkey_2 = hash2((unsigned int *)key, bloom.size);
	    if (bits[hashkey_2] != 1)
		check = 0;
	    if (tid < elements)
		printf("bloom: %d\n", check);
	    tid += stride;
	}
    }



/*****************************
BLOOM FILTER end
****************************/
    

    

    
    __device__ void
    transpose32(unsigned int *A) {
	int j, k;
        unsigned m, t;
        
        m = 0x0000FFFF;
        for (j = 16; j != 0; j = j >> 1, m = m ^ (m << j)) {
            for (k = 0; k < 32; k = (k + j + 1) & ~j) {
                t = (A[k] ^ (A[k+j] >> j)) & m;
                A[k] = A[k] ^ t;
                A[k+j] = A[k+j] ^ (t << j);
            }
        }
    }

        __device__ void
    transpose8rS64( unsigned char* A, unsigned char* B ) 
    {
    	unsigned long long x, t;
    	int i;

	for ( i = 0; i <= 7; i++ )
		x = x << 8 | A[1*i];

	t = (x ^ (x >> 7)) & 0x00AA00AA00AA00AALL;
	x = x ^ t ^ (t << 7);
	t = (x ^ (x >> 14)) & 0x0000CCCC0000CCCCLL;
	x = x ^ t ^ (t << 14);
	t = (x ^ (x >> 28)) & 0x00000000F0F0F0F0LL;
	x = x ^ t ^ (t << 28);

	for ( i = 7; i >= 0; i-- ) 
	{   // Store result into
		B[1*i] = x; x = x >> 8;
	}  // output array B.
    }



    __device__ void
    organize( unsigned int* A, unsigned int* B )
    {
	int i, j;
	int cnt = 0;
	for (j = 0; j < 32; j++)
	    for ( i = 0; i < 32 * 4; i += 32 )
	    {
		B[cnt] = A[i + j];
		cnt++;   
	    }
    }
    
    __device__ void
    organize_32( float* A, float* B )
    {
        int i = threadIdx.x;
        int cnt = threadIdx.x * 4;
        for (int j = 0; j < 128; j +=32)
	{
	    B[cnt] = A[i + j];
	    cnt++;   
	}
    }

       
    __device__ void
    organize_A( unsigned int* A, unsigned int* B )
    {
        for (int j = 0; j < 128; j++)
	{
	    B[j] = A[j];	
	}
    }
	
  
    
    __device__ void
    transpose(Descriptor * src, Descriptor *des, int size) {
              
        int block = blockIdx.x;
	int thread = threadIdx.x;

	const float * source = (float*)(src[block].features);       	
        float * destination = (float*)(des[block].features);

	    
        int s = thread * 4;
        int i;

	__shared__ float T[128];
	
	for (i = s; i < s + 4; i++)
	    T[i] = source[i];
	    
	
	__syncthreads();

	 
	//if(block == 0 && thread == 0) 
	//    printFeature((unsigned int*)T);

	 
	if (thread < 4)
	    transpose32((unsigned int*)&T[32 * thread]);     	    
       
	__syncthreads();
	 
	 
	organize_32(T, destination);
	 
	//if(thread == 0 && block == 0)
	//printFeature((unsigned int*)destination);	 	 
	 
	__syncthreads();

       
    }

    
#define DIMENSIONS 128

    __device__ __constant__ unsigned int gpu_idx[64] =
{
	0, 1, 2, 3,
	4, 5, 6, 7,
	8, 9, 10, 11,
	12, 13, 14, 15,
	128, 129, 130, 131,
	132, 133, 134, 135,
	136, 137, 138, 139,
	140, 141, 142, 143,
	256, 257, 258, 259,
	260, 261, 262, 263,
	264, 265, 266, 267,
	268, 269, 270, 271,
	384, 385, 386, 387,
	388, 389, 390, 391,
	392, 393, 394, 395,
	396, 397, 398, 399,
};


__device__ __constant__ unsigned int gpu_write_back[64] =
{
	384, 256, 128, 0, 
	388, 260, 132, 4, 
	392, 264, 136, 8, 
	396, 268, 140, 12, 
	385, 257, 129, 1, 
	389, 261, 133, 5, 
	393, 265, 137, 9, 
	397, 269, 141, 13, 
	386, 258, 130, 2, 
	390, 262, 134, 6, 
	394, 266, 138, 10, 
	398, 270, 142, 14, 
	387, 259, 131, 3, 
	391, 263, 135, 7, 
	395, 267, 139, 11, 
	399, 271, 143, 15,

};
    
    __global__ void
    transpose_descriptors_64(Descriptor *src, Descriptor *des)
    {
    
	unsigned char *ptr = (unsigned char *)(src + blockIdx.x);
	unsigned char *ptr_res = (unsigned char *)(des + blockIdx.x);

	int i;
	int start_pos, end_pos;
	int offset = 0;
	unsigned char C[8];                        //Local8x8 src
	unsigned char R[8];                        //Local8x8 des

	start_pos = gpu_idx[threadIdx.x];          //get starting index
	end_pos = gpu_write_back[threadIdx.x];     //get ending index
	ptr += start_pos;                          //set starting index
	ptr_res += end_pos;                        //set write back position

	//prepare 8x8 blocks for transpose
	for (i = 0; i < 8; i++) {
	    C[i] = ptr[offset];
	    offset += 16;
	} 

	transpose8rS64(C, R);
	offset = 0;
	for (i = 0; i < 8; i++) {
	    ptr_res[offset] = R[i];
	    offset += 16;
	} 
    }

        __global__ void
    transpose_descriptors_reverse_64(Descriptor *src, Descriptor *des)
    {
    
	unsigned char *ptr = (unsigned char *)(src + blockIdx.x);
	unsigned char *ptr_res = (unsigned char *)(des + blockIdx.x);

	int i;
	int start_pos, end_pos;
	int offset = 0;
	unsigned char C[8];                        //Local8x8 src
	unsigned char R[8];                        //Local8x8 des

	start_pos = gpu_write_back[threadIdx.x];     //get ending index
        end_pos = gpu_idx[threadIdx.x];          //get starting index
	ptr += start_pos;                          //set starting index
	ptr_res += end_pos;                        //set write back position

	//prepare 8x8 blocks for transpose
	for (i = 0; i < 8; i++) {
	    C[i] = ptr[offset];
	    offset += 16;
	} 

	transpose8rS64(C, R);
	__syncthreads(); //not nessesary when src and des are different buffers
	offset = 0;
	for (i = 0; i < 8; i++) {
	    ptr_res[offset] = R[i];
	    offset += 16;
	} 
    }
    
    __global__ void
    transpose_descriptors(Descriptor * src, int len, Descriptor * des) {

        if(blockIdx.x > len)
            return;

        transpose(src, des, len);
    }

    __global__ void
    compute_distance_print( int3* match_matrix, Descriptor* l, int l_len, Descriptor* r, int r_len , Descriptor * l_tra, Descriptor *r_tra) {
	printf("address: %d\n", l_tra);


	for(int i = 0; i < 4; i++) {
	    for(int j = 0; j < 10; j++)
		printf("%u\t", l_tra[i].features[j]);
	    printf("\n");
	}
	
	printf("-------\n");	
    }


    struct compare_descriptors { 
	__host__ __device__
	int operator()(const Descriptor &l, const Descriptor &r) const {
	    unsigned char *a, *b;
	    a = (unsigned char*)l.features;
	    b = (unsigned char*)r.features;

	    
	    a = (unsigned char*)&l;
	    b = (unsigned char*)&r;
	    
	    int i = 0;

	    while(i < 512) {
		if(a[i] < b[i]) return 2;
		if(a[i] > b[i]) return 0;
		
		if(a[i+1] < b[i+1]) return 2;
		if(a[i+1] > b[i+1]) return 0;
		
		if(a[i+2] < b[i+2]) return 2;
		if(a[i+2] > b[i+2]) return 0;
		
		if(a[i+3] < b[i+3]) return 2;
		if(a[i+3] > b[i+3]) return 0;
		
		i+=4;
	    }
	    
	    return 1;
	}
    };

    struct IndirectLookup
    {
	Descriptor* base;
	
	IndirectLookup( Descriptor* b ) : base(b) {}
	__device__
	inline bool operator()( int a, int b ) const
	    {
		int x = compare_descriptors()(base[a], base[b]);
                switch(x)
                {
                case 0 : return false;
                case 2 : return true;
                }
		
                return ( a < b );
	    }
    };

    __global__ void
    sort_descriptors_block(Descriptor *src, Descriptor *des, int elements, thrust::device_ptr<int> indexes )
    {
	int tid = threadIdx.x;
	int blockid = blockIdx.x;

	float *ptr = (float *)(src + blockid);
	float *ptr_res = (float *)(des + indexes[blockid]);

	ptr_res[tid] = ptr[tid];
	
    }

	    
    __global__ void
    show_distance( int3*       match_matrix,
		   Feature*    l_ext,
		   Descriptor* l_ori,
		   int*        l_fem,
		   int         l_len,
		   Feature*    r_ext,
		   Descriptor* r_ori,
		   int*        r_fem,
		   int         r_len )
    {
	int counter = 0;
	for( int i=0; i<l_len; i++ )
	{
	    const float4* lptr  = (const float4*)( &l_ori[i] );
	    const float4* rptr1 = (const float4*)( &r_ori[match_matrix[i].x] );
	    const float4* rptr2 = (const float4*)( &r_ori[match_matrix[i].y] );
	    float d1 = l2_in_t0( lptr, rptr1 );
	    float d2 = l2_in_t0( lptr, rptr2 );
	    if( threadIdx.x == 0 )
	    {
	  
		if( match_matrix[i].z )
		    counter++;
		/*printf( "accept feat %4d [%4d] matches feat %4d [%4d] ( 2nd feat %4d [%4d] ) dist %.3f vs %.3f\n",
		  l_fem[i], i,
		  r_fem[match_matrix[i].x], match_matrix[i].x,
		  r_fem[match_matrix[i].y], match_matrix[i].y,
		  d1, d2 );*/
	  
		//else
		/*printf( "reject feat %4d [%4d] matches feat %4d [%4d] ( 2nd feat %4d [%4d] ) dist %.3f vs %.3f\n",
		  l_fem[i], i,
		  r_fem[match_matrix[i].x], match_matrix[i].x,
		  r_fem[match_matrix[i].y], match_matrix[i].y,
		  d1, d2 );*/
	    }
	
	    __syncthreads();
      
	}
	if( threadIdx.x == 0 )
	    printf("Matches: %d\n", counter);
  
    }
    

    Descriptor * gpu_init(int SIZE) {
	Descriptor *tmp;

	cudaError_t err = cudaMalloc((void **)&tmp, SIZE * sizeof(Descriptor));
	if(err != cudaSuccess)
	    printf("%s\n", cudaGetErrorString(err));	
	return tmp;
    }


    
    void DeviceFeatures::match( DeviceFeatures* other, const popsift::Config& config )
    {

	int l_len = getDescriptorCount( );
	int r_len = other->getDescriptorCount( );
   
	cudaEvent_t start, stop;
	cudaEventCreate( &start );
	cudaEventCreate( &stop );
	float elapsedTime;

	cudaEventRecord( start, 0 );
   
	//cudaDeviceSetLimit(cudaLimitPrintfFifoSize, 1000000);

	int3* match_matrix = popsift::cuda::malloc_devT<int3>( l_len, __FILE__, __LINE__ );    
        POP_CHK;
	
	int offset = l_len % 2;
	offset = 0;
#if 0
	dim3 grid;
	grid.x = l_len;
	grid.y = 1;
	grid.z = 1;
	dim3 block;
	block.x = 32;
	block.y = 1;
	block.z = 1;

#else
    
	dim3 grid;
	grid.x = (l_len/2) + offset;
	grid.y = 1;
	grid.z = 1;
	dim3 block;
	block.x = 32;
	block.y = 2;
	block.z = 1;
#endif
	
	if ( config.getModeMatching() == popsift::Config::l2 )
	{
	     compute_distance_l2
		<<<grid,block>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len );

#if 0
	     float *buffer = (float *)malloc(r_len * 128 * sizeof(float));
	     cudaMemcpy(buffer, other->getDescriptors(), r_len * 128 * sizeof(float), cudaMemcpyDeviceToHost);
	     FILE *file;
	     file = fopen("siftdescR.txt", "wb");
	     fwrite(buffer, sizeof(float), r_len * 128, file);
	     fclose(file);
#endif
	     
	}
	else if ( config.getModeMatching() == popsift::Config::dot )
	{
#if 0
	    compute_distance_dot
		<<<grid,block>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len );
#elif 1
	    

	    compute_distance_dot_256
		<<<grid,block>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len );
	    
#elif 0
	    
	    float *norm;

	    cudaMalloc((void **)&norm, l_len * r_len * sizeof(float));
	    
	    compute_dot_no_sync
		<<<l_len/128,128>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(), r_len, norm);
#endif
	}
	else
	{

#if 1
	    
	    Descriptor *l_copy = gpu_init(l_len);
	    Descriptor *r_copy = gpu_init(r_len);
	    //Descriptor *tmpbuff = gpu_init(r_len); //hamming


	    const int SIZE = r_len; //unnessecary variable...
	    Table table; 
	    initialize_table_async( table, HASH_ENTRIES, SIZE * 2 ); //hash entries set equal to size for max performance
	    
	    //initialize mutual exclution locks. 
	    Lock lock[HASH_ENTRIES];
	    Lock *dev_lock;
	    cudaMalloc( (void**)&dev_lock, HASH_ENTRIES * sizeof( Lock ) );
	    cudaMemcpyAsync( dev_lock, lock, HASH_ENTRIES * sizeof( Lock ), cudaMemcpyHostToDevice );

	    //Lookup arrays
	    unsigned int *dev_start_idx;
	    unsigned int *dev_stop_idx;
	    
	    cudaMalloc((void **)&dev_start_idx, l_len * sizeof(unsigned int));
	    cudaMalloc((void **)&dev_stop_idx, l_len * sizeof(unsigned int));

	    
	    
	    //TRANSPOSE
	    //two streams..
	    cudaStream_t stream1, stream2;
	    cudaStreamCreate( &stream1 );
	    cudaStreamCreate( &stream2 );


	    transpose_descriptors_64
		<<<r_len,64,0,stream1>>>
		( other->getDescriptors(), r_copy );

	    //should be stream2
	    transpose_descriptors_64
		<<<l_len,64,0,stream1>>>
		( getDescriptors(), l_copy );

	    
	    
	    thrust::device_vector<int> d( SIZE );
	    thrust::device_ptr<int> indexes = &d[0];
	    
	    thrust::sequence(thrust::cuda::par.on(stream1), d.begin(), d.end() );
            IndirectLookup il_obj( r_copy ); //lcopy vs rcopy here. think r is best choise as it aligns with the standard setup. 
	    thrust::sort(thrust::cuda::par.on(stream1), d.begin(), d.end(), il_obj );

	    add_to_table<<<60,256,0,stream1>>>( r_copy, indexes, table, dev_lock, SIZE );

	    get_section_from_table
		<<<60, 256,0,stream1>>>
		( table, l_copy, l_len, r_len, dev_start_idx, dev_stop_idx );

	    sort_descriptors_block
	    	<<<r_len,128,0,stream1>>>
	    	( other->getDescriptors(), r_copy, r_len, indexes );
	    
	    
	    compute_dot_sorted_section_org
		<<<grid,block,0,stream1>>>
		( match_matrix, getDescriptors(), l_len, r_copy, r_len, dev_start_idx, dev_stop_idx );

	    cudaFree( r_copy );
	    cudaFree( l_copy );

	    cudaFree( dev_lock );

	    cudaFree( dev_start_idx );
	    cudaFree( dev_stop_idx );
	    
	    free_table(table);

	    cudaStreamDestroy(stream1);
	    cudaStreamDestroy(stream2);
	    
	    
#else
	    //Allocation
	    Descriptor *l_copy = gpu_init(l_len);
	    Descriptor *r_copy = gpu_init(r_len);

	    const int SIZE = r_len; //unnessecary variable...
	    Table table; 
	    initialize_table_async( table, HASH_ENTRIES, SIZE * 2 ); //hash entries set equal to size for max performance
	    
	    //initialize mutual exclution locks. 
	    Lock lock[HASH_ENTRIES];
	    Lock *dev_lock;
	    cudaMalloc( (void**)&dev_lock, HASH_ENTRIES * sizeof( Lock ) );
	    cudaMemcpyAsync( dev_lock, lock, HASH_ENTRIES * sizeof( Lock ), cudaMemcpyHostToDevice );

	    //Lookup arrays
	    unsigned int *dev_start_idx;
	    unsigned int *dev_stop_idx;
	    
	    cudaMalloc((void **)&dev_start_idx, l_len * sizeof(unsigned int));
	    cudaMalloc((void **)&dev_stop_idx, l_len * sizeof(unsigned int));

	    
	    
	    //TRANSPOSE
	    //two streams..
	    cudaStream_t stream1, stream2;
	    cudaStreamCreate( &stream1 );
	    cudaStreamCreate( &stream2 );


	    transpose_descriptors_64
		<<<r_len,64,0,stream1>>>
		( other->getDescriptors(), r_copy);

	    
	    transpose_descriptors_64
		<<<l_len,64,0,stream2>>>
		( getDescriptors(), l_copy);


	    
	    thrust::device_vector<int> d( SIZE );
	    thrust::device_ptr<int> indexes = &d[0];
	    
	    thrust::sequence(thrust::cuda::par.on(stream1), d.begin(), d.end() );
            IndirectLookup il_obj( r_copy ); //lcopy vs rcopy here. think r is best choise as it aligns with the standard setup. 
	    thrust::sort(thrust::cuda::par.on(stream1), d.begin(), d.end(), il_obj );

	    add_to_table<<<60,256,0,stream1>>>( r_copy, indexes, table, dev_lock, SIZE );

	    get_section_from_table
		<<<60, 256,0,stream1>>>
		( table, l_copy, l_len, r_len, dev_start_idx, dev_stop_idx );


	    compute_dot_in_section
		<<<grid,block,0,stream1>>>
		( match_matrix, getDescriptors(), l_len, other->getDescriptors(),  r_len, indexes, dev_start_idx, dev_stop_idx );

	    
#endif
	    
	}

	cudaEventRecord( stop, 0 );
	cudaEventSynchronize( stop );
	cudaEventElapsedTime( &elapsedTime, start, stop );
	printf( "Run-time:  %3.1f ms\n", elapsedTime );


	    
	show_distance
	    <<<1,32>>>
	    ( match_matrix,
	      getFeatures(),
	      getDescriptors(),
	      getReverseMap(),
	      l_len,
	      other->getFeatures(),
	      other->getDescriptors(),
	      other->getReverseMap(),
	      r_len );


	cudaFree( match_matrix );
    }

/*************************************************************
 * Feature
 *************************************************************/

    void Feature::print( std::ostream& ostr, bool write_as_uchar ) const
    {
	float sigval =  1.0f / ( sigma * sigma );

	for( int ori=0; ori<num_ori; ori++ ) {
	    ostr << xpos << " " << ypos << " "
		 << sigval << " 0 " << sigval << " ";
	    if( write_as_uchar ) {
		for( int i=0; i<128; i++ ) {
		    ostr << roundf(desc[ori]->features[i]) << " ";
		}
	    } else {
		ostr << std::setprecision(3);
		for( int i=0; i<128; i++ ) {
		    ostr << desc[ori]->features[i] << " ";
		}
		ostr << std::setprecision(6);
	    }
	    ostr << std::endl;
	}
    }

    std::ostream& operator<<( std::ostream& ostr, const Feature& feature )
    {
	feature.print( ostr, false );
	return ostr;
    }

} // namespace popsift
