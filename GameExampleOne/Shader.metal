//
//  Shader.metal
//  GameExampleOne
//
//  Created by Scott Mehus on 10/12/20.
//

#include <metal_stdlib>
#import "GPUObjects.h"
using namespace metal;

struct VertexOut {
    float4 position [[ position ]];
    float2 textureCoordinate;
};

vertex VertexOut vertex_main(uint vertexID [[ vertex_id ]],
                             constant TextVertex *vertexArray [[ buffer(17) ]],
                             constant vector_uint2 *viewportSizePointer [[buffer(18)]])
{

    VertexOut out;

    TextVertex text = vertexArray[vertexID];
    float2 pixelSpacePosition = text.position.xy;

    // Get the viewport size and cast to float.
    vector_float2 viewportSize = vector_float2(*viewportSizePointer);

    out.position = float4(0.0, 0.0, 0.0, 1.0);
    
    
    out.position.xy = pixelSpacePosition / (viewportSize / 2.0);

    out.textureCoordinate = text.textureCoordinate;

    return out;
}

fragment float4 fragment_main(VertexOut vertex_in [[ stage_in ]],
                              texture2d<float> atlasTexture [[ texture(0) ]])
{
    constexpr sampler s(filter::linear);
    float4 value = atlasTexture.sample(s, vertex_in.textureCoordinate);

    if (value.r < 1) {
        return float4(1, 0, 0, 1);
    } else {
        discard_fragment();
    }
}



