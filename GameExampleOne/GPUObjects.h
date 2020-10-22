//
//  GPUObjects.h
//  GameExampleOne
//
//  Created by Scott Mehus on 10/12/20.
//

#ifndef GPUObjects_h
#define GPUObjects_h

#include <simd/simd.h>

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 viewMatrix;
    matrix_float4x4 modelMatrix;
} Uniforms;

typedef struct
{
    // Positions in pixel space. A value of 100 indicates 100 pixels from the origin/center.
    vector_float2 position;

    // 2D texture coordinate
    vector_float2 textureCoordinate;
} TextVertex;

#endif /* GPUObjects_h */
