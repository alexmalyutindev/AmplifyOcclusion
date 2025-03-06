// Jimenez's "Interleaved Gradient Noise"
inline half JimenezNoise(const half2 xyPixelPos)
{
    return frac(52.9829189 * frac(dot(xyPixelPos, half2(0.06711056, 0.00583715))));
}

inline void GetSpatialDirections_Offsets_JimenezNoise(
    const half2 aScreenPos,
    const half2 aTextureSizeZW,
    out half outNoiseSpatialOffsets,
    out half outNoiseSpatialDirections
)
{
    #if defined( SHADER_API_D3D9 ) || defined( SHADER_API_MOBILE )
    // Spatial Offsets and Directions - s2016_pbs_activision_occlusion - Slide 93
    const half2 xyPixelPos = ceil( UnityStereoTransformScreenSpaceTex( aScreenPos ) * aTextureSizeZW );
    outNoiseSpatialOffsets = ( 1.0 / 4.0 ) * (half)( frac( ( xyPixelPos.y - xyPixelPos.x ) / 4.0 ) * 4.0 );

    outNoiseSpatialDirections = JimenezNoise( (half2)xyPixelPos );
    #else
    // Spatial Offsets and Directions - s2016_pbs_activision_occlusion - Slide 93
    const int2 xyPixelPos = aScreenPos * aTextureSizeZW;
    outNoiseSpatialOffsets = (1.0 / 4.0) * (half)((xyPixelPos.y - xyPixelPos.x) & 3);

    outNoiseSpatialDirections = JimenezNoise((half2)xyPixelPos);
    #endif
}
