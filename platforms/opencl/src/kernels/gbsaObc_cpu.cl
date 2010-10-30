#define TILE_SIZE 32

typedef struct {
    float x, y, z;
    float q;
    float fx, fy, fz, fw;
    float radius, scaledRadius;
    float bornSum;
    float bornRadius;
    float bornForce;
} AtomData;

/**
 * Compute the Born sum.
 */

__kernel __attribute__((reqd_work_group_size(WORK_GROUP_SIZE, 1, 1)))
void computeBornSum(__global float* global_bornSum, __global float4* posq, __global float2* global_params, __local AtomData* localData, __local float* tempBuffer,
#ifdef USE_CUTOFF
        __global ushort2* tiles, __global unsigned int* interactionCount, float4 periodicBoxSize, float4 invPeriodicBoxSize, unsigned int maxTiles, __global unsigned int* interactionFlags) {
#else
        unsigned int numTiles) {
#endif
#ifdef USE_CUTOFF
    unsigned int numTiles = interactionCount[0];
    unsigned int pos = get_group_id(0)*(numTiles > maxTiles ? NUM_BLOCKS*(NUM_BLOCKS+1)/2 : numTiles)/get_num_groups(0);
    unsigned int end = (get_group_id(0)+1)*(numTiles > maxTiles ? NUM_BLOCKS*(NUM_BLOCKS+1)/2 : numTiles)/get_num_groups(0);
#else
    unsigned int pos = get_group_id(0)*numTiles/get_num_groups(0);
    unsigned int end = (get_group_id(0)+1)*numTiles/get_num_groups(0);
#endif
    unsigned int lasty = 0xFFFFFFFF;

    while (pos < end) {
        // Extract the coordinates of this tile
        unsigned int x, y;
#ifdef USE_CUTOFF
        if (numTiles <= maxTiles) {
            ushort2 tileIndices = tiles[pos];
            x = tileIndices.x;
            y = tileIndices.y;
        }
        else
#endif
        {
            y = (unsigned int) floor(NUM_BLOCKS+0.5f-sqrt((NUM_BLOCKS+0.5f)*(NUM_BLOCKS+0.5f)-2*pos));
            x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
            if (x >= NUM_BLOCKS) { // Occasionally happens due to roundoff error.
                y++;
                x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
            }
        }

        // Load the data for this tile if we don't already have it cached.

        if (lasty != y) {
            for (int localAtomIndex = 0; localAtomIndex < TILE_SIZE; localAtomIndex++) {
                unsigned int j = y*TILE_SIZE + localAtomIndex;
                float4 tempPosq = posq[j];
                localData[localAtomIndex].x = tempPosq.x;
                localData[localAtomIndex].y = tempPosq.y;
                localData[localAtomIndex].z = tempPosq.z;
                localData[localAtomIndex].q = tempPosq.w;
                float2 tempParams = global_params[j];
                localData[localAtomIndex].radius = tempParams.x;
                localData[localAtomIndex].scaledRadius = tempParams.y;
            }
        }
        if (x == y) {
            // This tile is on the diagonal.

            for (unsigned int tgx = 0; tgx < TILE_SIZE; tgx++) {
                unsigned int atom1 = x*TILE_SIZE+tgx;
                float bornSum = 0.0f;
                float4 posq1 = posq[atom1];
                float2 params1 = global_params[atom1];
                for (unsigned int j = 0; j < TILE_SIZE; j++) {
                    float4 posq2 = (float4) (localData[j].x, localData[j].y, localData[j].z, localData[j].q);
                    float4 delta = (float4) (posq2.xyz - posq1.xyz, 0.0f);
#ifdef USE_PERIODIC
                    delta.xyz -= floor(delta.xyz*invPeriodicBoxSize.xyz+0.5f)*periodicBoxSize.xyz;
#endif
                    float r2 = dot(delta.xyz, delta.xyz);
#ifdef USE_CUTOFF
                    if (atom1 < NUM_ATOMS && y*TILE_SIZE+j < NUM_ATOMS && r2 < CUTOFF_SQUARED) {
#else
                    if (atom1 < NUM_ATOMS && y*TILE_SIZE+j < NUM_ATOMS) {
#endif
                        float invR = RSQRT(r2);
                        float r = RECIP(invR);
                        float2 params2 = (float2) (localData[j].radius, localData[j].scaledRadius);
                        float rScaledRadiusJ = r+params2.y;
                        if ((j != tgx) && (params1.x < rScaledRadiusJ)) {
                            float l_ij = RECIP(max(params1.x, fabs(r-params2.y)));
                            float u_ij = RECIP(rScaledRadiusJ);
                            float l_ij2 = l_ij*l_ij;
                            float u_ij2 = u_ij*u_ij;
                            float ratio = LOG(u_ij * RECIP(l_ij));
                            bornSum += l_ij - u_ij + 0.25f*r*(u_ij2-l_ij2) + (0.50f*invR*ratio) +
                                             (0.25f*params2.y*params2.y*invR)*(l_ij2-u_ij2);
                            if (params1.x < params2.x-r)
                                bornSum += 2.0f*(RECIP(params1.x)-l_ij);
                        }
                    }
                }

                // Write results.

                unsigned int offset = x*TILE_SIZE + tgx + get_group_id(0)*PADDED_NUM_ATOMS;
                global_bornSum[offset] += bornSum;
            }
        }
        else {
            // This is an off-diagonal tile.

            for (int tgx = 0; tgx < TILE_SIZE; tgx++)
                localData[tgx].bornSum = 0.0f;

            // Compute the full set of interactions in this tile.

            for (unsigned int tgx = 0; tgx < TILE_SIZE; tgx++) {
                unsigned int atom1 = x*TILE_SIZE+tgx;
                float bornSum = 0.0f;
                float4 posq1 = posq[atom1];
                float2 params1 = global_params[atom1];
                for (unsigned int j = 0; j < TILE_SIZE; j++) {
                    float4 posq2 = (float4) (localData[j].x, localData[j].y, localData[j].z, localData[j].q);
                    float4 delta = (float4) (posq2.xyz - posq1.xyz, 0.0f);
#ifdef USE_PERIODIC
                    delta.xyz -= floor(delta.xyz*invPeriodicBoxSize.xyz+0.5f)*periodicBoxSize.xyz;
#endif
                    float r2 = dot(delta.xyz, delta.xyz);
#ifdef USE_CUTOFF
                    if (atom1 < NUM_ATOMS && y*TILE_SIZE+j < NUM_ATOMS && r2 < CUTOFF_SQUARED) {
#else
                    if (atom1 < NUM_ATOMS && y*TILE_SIZE+j < NUM_ATOMS) {
#endif
                        float invR = RSQRT(r2);
                        float r = RECIP(invR);


                        float2 params2 = (float2) (localData[j].radius, localData[j].scaledRadius);
                        float rScaledRadiusJ = r+params2.y;
                        if (params1.x < rScaledRadiusJ) {
                            float l_ij = RECIP(max(params1.x, fabs(r-params2.y)));
                            float u_ij = RECIP(rScaledRadiusJ);
                            float l_ij2 = l_ij*l_ij;
                            float u_ij2 = u_ij*u_ij;
                            float ratio = LOG(u_ij * RECIP(l_ij));
                            bornSum += l_ij - u_ij + 0.25f*r*(u_ij2-l_ij2) + (0.50f*invR*ratio) +
                                             (0.25f*params2.y*params2.y*invR)*(l_ij2-u_ij2);
                            if (params1.x < params2.x-r)
                                bornSum += 2.0f*(RECIP(params1.x)-l_ij);
                        }
                        float rScaledRadiusI = r+params1.y;
                        if (params2.x < rScaledRadiusI) {
                            float l_ij = RECIP(max(params2.x, fabs(r-params1.y)));
                            float u_ij = RECIP(rScaledRadiusI);
                            float l_ij2 = l_ij*l_ij;
                            float u_ij2 = u_ij*u_ij;
                            float ratio = LOG(u_ij * RECIP(l_ij));
                            float term = l_ij - u_ij + 0.25f*r*(u_ij2-l_ij2) + (0.50f*invR*ratio) +
                                             (0.25f*params1.y*params1.y*invR)*(l_ij2-u_ij2);
                            if (params2.x < params1.x-r)
                                term += 2.0f*(RECIP(params2.x)-l_ij);
                            localData[j].bornSum += term;
                        }
                    }
                }

               // Write results for atom1.

                unsigned int offset = atom1 + get_group_id(0)*PADDED_NUM_ATOMS;
                global_bornSum[offset] += localData[tgx].bornSum;
            }
        }

        // Write results

        for (int tgx = 0; tgx < TILE_SIZE; tgx++) {
            unsigned int offset = y*TILE_SIZE+tgx + get_group_id(0)*PADDED_NUM_ATOMS;
            global_bornSum[offset] += localData[tgx].bornSum;
        }
        lasty = y;
        pos++;
    }
}

/**
 * First part of computing the GBSA interaction.
 */

__kernel __attribute__((reqd_work_group_size(WORK_GROUP_SIZE, 1, 1)))
void computeGBSAForce1(__global float4* forceBuffers, __global float* energyBuffer,
        __global float4* posq, __global float* global_bornRadii,
        __global float* global_bornForce, __local AtomData* localData, __local float4* tempBuffer,
#ifdef USE_CUTOFF
        __global ushort2* tiles, __global unsigned int* interactionCount, float4 periodicBoxSize, float4 invPeriodicBoxSize, unsigned int maxTiles, __global unsigned int* interactionFlags) {
#else
        unsigned int numTiles) {
#endif
#ifdef USE_CUTOFF
    unsigned int numTiles = interactionCount[0];
    unsigned int pos = get_group_id(0)*(numTiles > maxTiles ? NUM_BLOCKS*(NUM_BLOCKS+1)/2 : numTiles)/get_num_groups(0);
    unsigned int end = (get_group_id(0)+1)*(numTiles > maxTiles ? NUM_BLOCKS*(NUM_BLOCKS+1)/2 : numTiles)/get_num_groups(0);
#else
    unsigned int pos = get_group_id(0)*numTiles/get_num_groups(0);
    unsigned int end = (get_group_id(0)+1)*numTiles/get_num_groups(0);
#endif
    float energy = 0.0f;
    unsigned int lasty = 0xFFFFFFFF;

    while (pos < end) {
        // Extract the coordinates of this tile
        unsigned int x, y;
#ifdef USE_CUTOFF
        if (numTiles <= maxTiles) {
            ushort2 tileIndices = tiles[pos];
            x = tileIndices.x;
            y = tileIndices.y;
        }
        else
#endif
        {
            y = (unsigned int) floor(NUM_BLOCKS+0.5f-sqrt((NUM_BLOCKS+0.5f)*(NUM_BLOCKS+0.5f)-2*pos));
            x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
            if (x >= NUM_BLOCKS) { // Occasionally happens due to roundoff error.
                y++;
                x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
            }
        }

        // Load the data for this tile if we don't already have it cached.

        if (lasty != y) {
            for (int localAtomIndex = 0; localAtomIndex < TILE_SIZE; localAtomIndex++) {
                unsigned int j = y*TILE_SIZE + localAtomIndex;
                float4 tempPosq = posq[j];
                localData[localAtomIndex].x = tempPosq.x;
                localData[localAtomIndex].y = tempPosq.y;
                localData[localAtomIndex].z = tempPosq.z;
                localData[localAtomIndex].q = tempPosq.w;
                localData[localAtomIndex].bornRadius = global_bornRadii[j];
            }
        }
        if (x == y) {
            // This tile is on the diagonal.

            for (unsigned int tgx = 0; tgx < TILE_SIZE; tgx++) {
                unsigned int atom1 = x*TILE_SIZE+tgx;
                float4 force = 0.0f;
                float4 posq1 = posq[atom1];
                float bornRadius1 = global_bornRadii[atom1];
                for (unsigned int j = 0; j < TILE_SIZE; j++) {
                    float4 posq2 = (float4) (localData[j].x, localData[j].y, localData[j].z, localData[j].q);
                    float4 delta = (float4) (posq2.xyz - posq1.xyz, 0.0f);
#ifdef USE_PERIODIC
                    delta.xyz -= floor(delta.xyz*invPeriodicBoxSize.xyz+0.5f)*periodicBoxSize.xyz;
#endif
                    float r2 = dot(delta.xyz, delta.xyz);
#ifdef USE_CUTOFF
                    if (atom1 < NUM_ATOMS && y*TILE_SIZE+j < NUM_ATOMS && r2 < CUTOFF_SQUARED) {
#else
                    if (atom1 < NUM_ATOMS && y*TILE_SIZE+j < NUM_ATOMS) {
#endif
                        float invR = RSQRT(r2);
                        float r = RECIP(invR);
                        float bornRadius2 = localData[j].bornRadius;
                        float alpha2_ij = bornRadius1*bornRadius2;
                        float D_ij = r2*RECIP(4.0f*alpha2_ij);
                        float expTerm = EXP(-D_ij);
                        float denominator2 = r2 + alpha2_ij*expTerm;
                        float denominator = SQRT(denominator2);
                        float tempEnergy = (PREFACTOR*posq1.w*posq2.w)*RECIP(denominator);
                        float Gpol = tempEnergy*RECIP(denominator2);
                        float dGpol_dalpha2_ij = -0.5f*Gpol*expTerm*(1.0f+D_ij);
                        force.w += dGpol_dalpha2_ij*bornRadius2;
                        float dEdR = Gpol*(1.0f - 0.25f*expTerm);
                        energy += 0.5f*tempEnergy;
                        force.xyz -= delta.xyz*dEdR;
                    }
                }

                // Write results.

                unsigned int offset = x*TILE_SIZE + tgx + get_group_id(0)*PADDED_NUM_ATOMS;
                forceBuffers[offset].xyz = forceBuffers[offset].xyz+force.xyz;
                global_bornForce[offset] += force.w;
            }
        }
        else {
            // This is an off-diagonal tile.

            for (int tgx = 0; tgx < TILE_SIZE; tgx++) {
                localData[tgx].fx = 0.0f;
                localData[tgx].fy = 0.0f;
                localData[tgx].fz = 0.0f;
                localData[tgx].fw = 0.0f;
            }

            // Compute the full set of interactions in this tile.

            for (unsigned int tgx = 0; tgx < TILE_SIZE; tgx++) {
                unsigned int atom1 = x*TILE_SIZE+tgx;
                float4 force = 0.0f;
                float4 posq1 = posq[atom1];
                float bornRadius1 = global_bornRadii[atom1];
                for (unsigned int j = 0; j < TILE_SIZE; j++) {
                    float4 posq2 = (float4) (localData[j].x, localData[j].y, localData[j].z, localData[j].q);
                    float4 delta = (float4) (posq2.xyz - posq1.xyz, 0.0f);
#ifdef USE_PERIODIC
                    delta.xyz -= floor(delta.xyz*invPeriodicBoxSize.xyz+0.5f)*periodicBoxSize.xyz;
#endif
                    float r2 = dot(delta.xyz, delta.xyz);
#ifdef USE_CUTOFF
                    if (atom1 < NUM_ATOMS && y*TILE_SIZE+j < NUM_ATOMS && r2 < CUTOFF_SQUARED) {
#else
                    if (atom1 < NUM_ATOMS && y*TILE_SIZE+j < NUM_ATOMS) {
#endif
                        float invR = RSQRT(r2);
                        float r = RECIP(invR);
                        float bornRadius2 = localData[j].bornRadius;
                        float alpha2_ij = bornRadius1*bornRadius2;
                        float D_ij = r2*RECIP(4.0f*alpha2_ij);
                        float expTerm = EXP(-D_ij);
                        float denominator2 = r2 + alpha2_ij*expTerm;
                        float denominator = SQRT(denominator2);
                        float tempEnergy = (PREFACTOR*posq1.w*posq2.w)*RECIP(denominator);
                        float Gpol = tempEnergy*RECIP(denominator2);
                        float dGpol_dalpha2_ij = -0.5f*Gpol*expTerm*(1.0f+D_ij);
                        force.w += dGpol_dalpha2_ij*bornRadius2;
                        float dEdR = Gpol*(1.0f - 0.25f*expTerm);
                        energy += tempEnergy;
                        delta.xyz *= dEdR;
                        force.xyz -= delta.xyz;
                        localData[j].fx += delta.x;
                        localData[j].fy += delta.y;
                        localData[j].fz += delta.z;
                        localData[j].fw += dGpol_dalpha2_ij*bornRadius1;
                    }
                }

                // Write results for atom1.

                unsigned int offset = atom1 + get_group_id(0)*PADDED_NUM_ATOMS;
                forceBuffers[offset].xyz = forceBuffers[offset].xyz+force.xyz;
            }
        }

        // Write results

        for (int tgx = 0; tgx < TILE_SIZE; tgx++) {
            unsigned int offset = y*TILE_SIZE+tgx + get_group_id(0)*PADDED_NUM_ATOMS;
            float4 f = forceBuffers[offset];
            f.x += localData[tgx].fx;
            f.y += localData[tgx].fy;
            f.z += localData[tgx].fz;
            forceBuffers[offset] = f;
            global_bornForce[offset] += localData[tgx].fw;
        }
        lasty = y;
        pos++;
    }
    energyBuffer[get_global_id(0)] += energy;
}