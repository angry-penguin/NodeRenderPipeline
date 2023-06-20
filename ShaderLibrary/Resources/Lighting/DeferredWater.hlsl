#ifndef DEFERRED_WATER_INCLUDED
#define DEFERRED_WATER_INCLUDED

#include "Packages/com.arycama.noderenderpipeline/ShaderLibrary/Lighting.hlsl"
#include "Packages/com.arycama.noderenderpipeline/ShaderLibrary/GGXExtensions.hlsl"
#include "Packages/com.arycama.noderenderpipeline/ShaderLibrary/Brdf.hlsl"
#include "Packages/com.arycama.noderenderpipeline/ShaderLibrary/Deferred.hlsl"

#ifdef __INTELLISENSE__
	#define LIGHT_COUNT_ONE 
	#define LIGHT_COUNT_TWO
#endif

Texture2D<float4> _WaterNormalFoam, _WaterRoughnessMask;
Texture2D<float3> _WaterEmission, _UnderwaterResult;
Texture2D<float> _Depth, _UnderwaterDepth;

Texture2D<float> _UnityFBInput0;

float3 _Extinction, _Color, _LightColor0, _LightDirection0, _LightColor1, _LightDirection1;
float _RefractOffset, _Steps;

float4 Vertex(uint id : SV_VertexID) : SV_Position
{
	return GetFullScreenTriangleVertexPosition(id);
}

GBufferOut Fragment(float4 positionCS : SV_Position)
{
	float waterDepth = _UnityFBInput0[positionCS.xy];
	float4 waterNormalFoam = _WaterNormalFoam[positionCS.xy];
	
	float3 positionWS = PixelToWorld(positionCS.xy, waterDepth);
	float linearWaterDepth = LinearEyeDepth(waterDepth);
	float distortion = _RefractOffset * _ScreenSize.y * abs(CameraAspect) * 0.25 / linearWaterDepth;
	
	float3 N = UnpackNormalOctQuadEncode(2.0 * Unpack888ToFloat2(waterNormalFoam.xyz) - 1.0);
	float2 uvOffset = N.xz * distortion;
	float2 refractionUv = uvOffset * _ScreenSize.xy + positionCS.xy;
	float2 refractedPositionSS = clamp(refractionUv, 0, _ScreenSize.xy - 1);
	float underwaterDepth = _UnderwaterDepth[refractedPositionSS];
	float underwaterDistance = LinearEyeDepth(underwaterDepth) - linearWaterDepth;

	// Clamp underwater depth if sampling a non-underwater pixel
	if (underwaterDistance <= 0.0)
	{
		underwaterDepth = _UnderwaterDepth[positionCS.xy];
		underwaterDistance = max(0.0, LinearEyeDepth(underwaterDepth) - linearWaterDepth);
		refractionUv = positionCS.xy;
	}
	
	float3 V = normalize(positionWS);
	underwaterDistance /= dot(V, _InvViewMatrix._m02_m12_m22);
	
	#if defined(LIGHT_COUNT_ONE) || defined(LIGHT_COUNT_TWO)
		// Slight optimisation, only calculate atmospheric transmittance at surface
		float3 lightColor0 = RcpFourPi * ApplyExposure(_LightColor0) * TransmittanceToAtmosphere(positionWS + _PlanetOffset, _LightDirection0, _LinearClampSampler);
	#endif
	
	#ifdef LIGHT_COUNT_TWO
		// Slight optimisation, only calculate atmospheric transmittance at surface
		float3 lightColor1 = RcpFourPi * ApplyExposure(_LightColor1) * TransmittanceToAtmosphere(positionWS + _PlanetOffset, _LightDirection1, _LinearClampSampler);
	#endif

	float2 noise = BlueNoise2D(positionCS.xy);
	
	// Select random channel
	float3 channelMask = floor(noise.y * 3.0) == float3(0.0, 1.0, 2.0);
	
	float3 luminance = 0.0;
	
	#define NO_PDF 1
	
	#ifdef SINGLE_SAMPLE
	{
		float xi = noise.x;
	#else
	for (float i = noise.x; i < _Steps; i++)
	{
		float xi = i / _Steps;
	#endif
		
		float t = -log(1.0 - xi * (1.0 - exp(-dot(_Extinction, channelMask) * underwaterDistance))) / dot(_Extinction, channelMask);
		float3 tr = _Extinction / (exp(_Extinction * t) - _Extinction * rcp(_Extinction * exp(_Extinction * (underwaterDistance - t))));
		float pdf = dot(tr, 1.0 / 3.0);
		float3 P = positionWS + V * t;
		
		#if defined(LIGHT_COUNT_ONE) || defined(LIGHT_COUNT_TWO)
			float attenuation = DirectionalLightShadow(P, 0, 0.5, false);
			if(attenuation > 0.0)
			{
				attenuation *= CloudTransmittanceLevelZero(P);
				if(attenuation > 0.0)
				{
					float shadowDistance0 = max(0.0, positionWS.y - P.y) / max(1e-6, saturate(_LightDirection0.y));
					float3 shadowPosition = MultiplyPoint3x4(_WaterShadowMatrix, P);
					if (all(saturate(shadowPosition) == shadowPosition))
					{
						float shadowDepth = _WaterShadows.SampleLevel(_LinearClampSampler, shadowPosition.xy, 0.0);
						shadowDistance0 = saturate(shadowDepth - shadowPosition.z) * _WaterShadowFar;
					}

					float3 ls = lightColor0 * attenuation * exp(-_Extinction * shadowDistance0);
				
					#if NO_PDF
						luminance += exp(-_Extinction * t) * _Extinction * ls / pdf;
					#else
						luminance += exp(-_Extinction * t) * _Extinction * ls / pdf;
					#endif
				}
			}
		#endif
		
		#ifdef LIGHT_COUNT_TWO
			float shadowDistance1 = max(0.0, positionWS.y - P.y) / max(1e-6, saturate(_LightDirection1.y));
		
			//#if NO_PDF
			//	luminance += exp(-_Extinction * shadowDistance1) * lightColor1;
			//#else
			//	luminance += exp(-_Extinction * shadowDistance1) * _Extinction * (exp(-_Extinction * shadowDistance1) * lightColor1) / pdf;
			//#endif
		#endif
	}
	
	float3 transmittance = exp(-underwaterDistance * _Extinction);
	float3 opacity = OpacityFromTransmittance(transmittance);
	
	#ifndef SINGLE_SAMPLE
		luminance /= _Steps;
	#endif
	
	#if NO_PDF
		//luminance *= 3.0;
	#endif
	
	// Ambient 
	//luminance += _AmbientSh[0].xyz * rcp(2.0 * sqrt(Pi)) * (1.0 - transmittance);
	luminance *= _Color;

	if(underwaterDepth != _FarClipValue)
		luminance += _UnderwaterResult[refractionUv] * transmittance;
	
	// Apply roughness to transmission
	float4 waterRoughnessMask = _WaterRoughnessMask[positionCS.xy];
	float perceptualRoughness = ConvertAnisotropicPerceptualRoughnessToPerceptualRoughness(waterRoughnessMask.gb);
	luminance *= (1.0 - waterNormalFoam.a) * GGXDiffuse(1.0, dot(N, -V), perceptualRoughness, 0.04) * Pi;

	GBufferOut output;
	output.gBuffer0 = PackGBufferAlbedoTranslucency(waterNormalFoam.a, 0.0, positionCS.xy);
	output.gBuffer1 = float4(waterNormalFoam.xyz, 0.0);
	output.gBuffer2 = waterRoughnessMask;
	output.gBuffer3 = float4(waterNormalFoam.xyz, 1.0);
	output.emission = luminance;
	return output;
}

#endif