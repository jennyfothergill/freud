#include "PMFXYZ.h"
#include "ScopedGILRelease.h"

#include <stdexcept>
#ifdef __SSE2__
#include <emmintrin.h>
#endif

#ifdef ENABLE_OPENMP
#include <omp.h>
#endif

#include "VectorMath.h"

using namespace std;

using namespace tbb;

/*! \internal
    \file PMFXYZ.cc
    \brief Routines for computing 3D anisotropic potential of mean force
*/

namespace freud { namespace pmft {

PMFXYZ::PMFXYZ(float max_x, float max_y, float max_z, unsigned int nbins_x, unsigned int nbins_y, unsigned int nbins_z)
    : m_box(trajectory::Box()), m_max_x(max_x), m_max_y(max_y), m_max_z(max_z),
      m_nbins_x(nbins_x), m_nbins_y(nbins_y), m_nbins_z(nbins_z)
    {
    if (nbins_x < 1)
        throw invalid_argument("must be at least 1 bin in x");
    if (nbins_y < 1)
        throw invalid_argument("must be at least 1 bin in y");
    if (nbins_z < 1)
        throw invalid_argument("must be at least 1 bin in z");
    if (max_x < 0.0f)
        throw invalid_argument("max_x must be positive");
    if (max_y < 0.0f)
        throw invalid_argument("max_y must be positive");
    if (max_z < 0.0f)
        throw invalid_argument("max_z must be positive");

    // calculate dx, dy, dz
    m_dx = 2.0 * m_max_x / float(m_nbins_x);
    m_dy = 2.0 * m_max_y / float(m_nbins_y);
    m_dz = 2.0 * m_max_z / float(m_nbins_z);

    if (m_dx > max_x)
        throw invalid_argument("max_x must be greater than dx");
    if (m_dy > max_y)
        throw invalid_argument("max_y must be greater than dy");
    if (m_dz > max_z)
        throw invalid_argument("max_z must be greater than dz");

    // precompute the bin center positions for x
    m_x_array = boost::shared_array<float>(new float[m_nbins_x]);
    for (unsigned int i = 0; i < m_nbins_x; i++)
        {
        float x = float(i) * m_dx;
        float nextx = float(i+1) * m_dx;
        m_x_array[i] = -m_max_x + ((x + nextx) / 2.0);
        }

    // precompute the bin center positions for y
    m_y_array = boost::shared_array<float>(new float[m_nbins_y]);
    for (unsigned int i = 0; i < m_nbins_y; i++)
        {
        float y = float(i) * m_dy;
        float nexty = float(i+1) * m_dy;
        m_y_array[i] = -m_max_y + ((y + nexty) / 2.0);
        }

    // precompute the bin center positions for z
    m_z_array = boost::shared_array<float>(new float[m_nbins_z]);
    for (unsigned int i = 0; i < m_nbins_z; i++)
        {
        float z = float(i) * m_dz;
        float nextz = float(i+1) * m_dz;
        m_z_array[i] = -m_max_z + ((z + nextz) / 2.0);
        }

    // create and populate the pcf_array
    m_pcf_array = boost::shared_array<unsigned int>(new unsigned int[m_nbins_x * m_nbins_y * m_nbins_z]);
    memset((void*)m_pcf_array.get(), 0, sizeof(unsigned int)*m_nbins_x*m_nbins_y*m_nbins_z);

    m_lc = new locality::LinkCell(m_box, sqrtf(m_max_x*m_max_x + m_max_y*m_max_y + m_max_z*m_max_z));
    }

PMFXYZ::~PMFXYZ()
    {
    for (tbb::enumerable_thread_specific<unsigned int *>::iterator i = m_local_pcf_array.begin(); i != m_local_pcf_array.end(); ++i)
        {
        delete[] (*i);
        }
    delete m_lc;
    }

class CombinePCFXYZ
    {
    private:
        unsigned int m_nbins_x;
        unsigned int m_nbins_y;
        unsigned int m_nbins_z;
        unsigned int *m_pcf_array;
        tbb::enumerable_thread_specific<unsigned int *>& m_local_pcf_array;
    public:
        CombinePCFXYZ(unsigned int nbins_x,
                      unsigned int nbins_y,
                      unsigned int nbins_z,
                      unsigned int *pcf_array,
                      tbb::enumerable_thread_specific<unsigned int *>& local_pcf_array)
            : m_nbins_x(nbins_x), m_nbins_y(nbins_y), m_nbins_z(nbins_z), m_pcf_array(pcf_array),
              m_local_pcf_array(local_pcf_array)
        {
        }
        void operator()( const blocked_range<size_t> &myBin ) const
            {
            Index3D b_i = Index3D(m_nbins_x, m_nbins_y, m_nbins_z);
            for (size_t i = myBin.begin(); i != myBin.end(); i++)
                {
                for (size_t j = 0; j < m_nbins_y; j++)
                    {
                    for (size_t k = 0; k < m_nbins_z; k++)
                        {
                        for (tbb::enumerable_thread_specific<unsigned int *>::const_iterator local_bins = m_local_pcf_array.begin();
                             local_bins != m_local_pcf_array.end(); ++local_bins)
                            {
                            m_pcf_array[b_i((int)i, (int)j, (int)k)] += (*local_bins)[b_i((int)i, (int)j, (int)k)];
                            }
                        }
                    }
                }
            }
    };

//! \internal
/*! \brief Helper class to compute PMF in parallel with the cell list
*/
class ComputePMFT
    {
    private:
        tbb::enumerable_thread_specific<unsigned int *>& m_pcf_array;
        unsigned int m_nbins_x;
        unsigned int m_nbins_y;
        unsigned int m_nbins_z;
        const trajectory::Box m_box;
        const float m_max_x;
        const float m_max_y;
        const float m_max_z;
        const float m_dx;
        const float m_dy;
        const float m_dz;
        const locality::LinkCell *m_lc;
        const vec3<float> *m_ref_points;
        const quat<float> *m_ref_orientations;
        const unsigned int m_Nref;
        const vec3<float> *m_points;
        const quat<float> *m_orientations;
        const unsigned int m_Np;
        const quat<float> *m_face_orientations;
        const unsigned int m_Nfaces;
    public:
        ComputePMFT(tbb::enumerable_thread_specific<unsigned int *>& pcf_array,
                    unsigned int nbins_x,
                    unsigned int nbins_y,
                    unsigned int nbins_z,
                    const trajectory::Box &box,
                    const float max_x,
                    const float max_y,
                    const float max_z,
                    const float dx,
                    const float dy,
                    const float dz,
                    const locality::LinkCell *lc,
                    const vec3<float> *ref_points,
                    const quat<float> *ref_orientations,
                    unsigned int Nref,
                    const vec3<float> *points,
                    const quat<float> *orientations,
                    unsigned int Np,
                    const quat<float> *face_orientations,
                    const unsigned int Nfaces)
            : m_pcf_array(pcf_array), m_nbins_x(nbins_x), m_nbins_y(nbins_y), m_nbins_z(nbins_z), m_box(box),
              m_max_x(max_x), m_max_y(max_y), m_max_z(max_z), m_dx(dx), m_dy(dy), m_dz(dz), m_lc(lc),
              m_ref_points(ref_points), m_ref_orientations(ref_orientations), m_Nref(Nref), m_points(points),
              m_orientations(orientations), m_Np(Np), m_face_orientations(face_orientations), m_Nfaces(Nfaces)
        {
        }
        void operator()( const blocked_range<size_t> &myR ) const
            {
            assert(m_ref_points);
            assert(m_points);
            assert(m_Nref > 0);
            assert(m_Np > 0);

            // precalc some values for faster computation within the loop
            float dx_inv = 1.0f / m_dx;
            float maxxsq = m_max_x * m_max_x;
            float dy_inv = 1.0f / m_dy;
            float maxysq = m_max_y * m_max_y;
            float dz_inv = 1.0f / m_dz;
            float maxzsq = m_max_z * m_max_z;

            Index3D b_i = Index3D(m_nbins_x, m_nbins_y, m_nbins_z);
            Index2D q_i = Index2D(m_Nfaces, m_Np);

            bool exists;
            m_pcf_array.local(exists);
            if (! exists)
                {
                m_pcf_array.local() = new unsigned int [m_nbins_x*m_nbins_y*m_nbins_z];
                memset((void*)m_pcf_array.local(), 0, sizeof(unsigned int)*m_nbins_x*m_nbins_y*m_nbins_z);
                }

            // for each reference point
            for (size_t i = myR.begin(); i != myR.end(); i++)
                {
                // get the cell the point is in
                vec3<float> ref = m_ref_points[i];
                unsigned int ref_cell = m_lc->getCell(ref);

                // loop over all neighboring cells
                const std::vector<unsigned int>& neigh_cells = m_lc->getCellNeighbors(ref_cell);
                for (unsigned int neigh_idx = 0; neigh_idx < neigh_cells.size(); neigh_idx++)
                    {
                    unsigned int neigh_cell = neigh_cells[neigh_idx];

                    // iterate over the particles in that cell
                    locality::LinkCell::iteratorcell it = m_lc->itercell(neigh_cell);
                    for (unsigned int j = it.next(); !it.atEnd(); j=it.next())
                        {
                        // make sure that the particles are wrapped into the box
                        vec3<float> delta = m_box.wrap(m_points[j] - ref);
                        float rsq = dot(delta, delta);

                        // check that the particle is not checking itself
                        // 1e-6 is an arbitrary value that could be set differently if needed
                        if (rsq < 1e-6)
                            {
                            continue;
                            }
                        for (unsigned int k=0; k<m_Nfaces; k++)
                            {
                            // create tmp vector
                            vec3<float> my_vector(delta);
                            // rotate vector

                            // create the reference point quaternion
                            quat<float> q(m_ref_orientations[i]);
                            // create the extra quaternion
                            quat<float> qe(m_face_orientations[q_i(k, i)]);
                            // create point vector
                            vec3<float> v(delta);
                            // rotate the vector
                            v = rotate(conj(q), v);
                            v = rotate(qe, v);

                            float x = v.x + m_max_x;
                            float y = v.y + m_max_y;
                            float z = v.z + m_max_z;

                            // bin that point
                            float binx = floorf(x * dx_inv);
                            float biny = floorf(y * dy_inv);
                            float binz = floorf(z * dz_inv);
                            // fast float to int conversion with truncation
                            #ifdef __SSE2__
                            unsigned int ibinx = _mm_cvtt_ss2si(_mm_load_ss(&binx));
                            unsigned int ibiny = _mm_cvtt_ss2si(_mm_load_ss(&biny));
                            unsigned int ibinz = _mm_cvtt_ss2si(_mm_load_ss(&binz));
                            #else
                            unsigned int ibinx = (unsigned int)(binx);
                            unsigned int ibiny = (unsigned int)(biny);
                            unsigned int ibinz = (unsigned int)(binz);
                            #endif

                            // increment the bin
                            if ((ibinx < m_nbins_x) && (ibiny < m_nbins_y) && (ibinz < m_nbins_z))
                                {
                                ++m_pcf_array.local()[b_i(ibinx, ibiny, ibinz)];
                                }
                            }
                        }
                    }
                } // done looping over reference points
            }
    };

//! \internal
//! helper function to reduce the thread specific arrays into the boost array
void PMFXYZ::reducePCF()
    {
    memset((void*)m_pcf_array.get(), 0, sizeof(unsigned int)*m_nbins_x*m_nbins_y*m_nbins_z);
    parallel_for(blocked_range<size_t>(0,m_nbins_x),
                 CombinePCFXYZ(m_nbins_x,
                               m_nbins_y,
                               m_nbins_z,
                               m_pcf_array.get(),
                               m_local_pcf_array));
    }

//! Get a reference to the PCF array
boost::shared_array<unsigned int> PMFXYZ::getPCF()
    {
    reducePCF();
    return m_pcf_array;
    }

//! \internal
/*! \brief Function to reset the pcf array if needed e.g. calculating between new particle types
*/
void PMFXYZ::resetPCF()
    {
    for (tbb::enumerable_thread_specific<unsigned int *>::iterator i = m_local_pcf_array.begin(); i != m_local_pcf_array.end(); ++i)
        {
        memset((void*)(*i), 0, sizeof(unsigned int)*m_nbins_x*m_nbins_y*m_nbins_z);
        }
    // memset((void*)m_pcf_array.get(), 0, sizeof(unsigned int)*m_nbins_x*m_nbins_y*m_nbins_z);
    }

//! \internal
/*! \brief Helper function to direct the calculation to the correct helper class
*/
void PMFXYZ::accumulate(trajectory::Box& box,
                        vec3<float> *ref_points,
                        quat<float> *ref_orientations,
                        unsigned int Nref,
                        vec3<float> *points,
                        quat<float> *orientations,
                        unsigned int Np,
                        quat<float> *face_orientations,
                        unsigned int Nfaces)
    {
    m_box = box;
    m_lc->computeCellList(m_box, points, Np);
    parallel_for(blocked_range<size_t>(0,Nref),
                 ComputePMFT(m_local_pcf_array,
                             m_nbins_x,
                             m_nbins_y,
                             m_nbins_z,
                             m_box,
                             m_max_x,
                             m_max_y,
                             m_max_z,
                             m_dx,
                             m_dy,
                             m_dz,
                             m_lc,
                             ref_points,
                             ref_orientations,
                             Nref,
                             points,
                             orientations,
                             Np,
                             face_orientations,
                             Nfaces));
    }

}; }; // end namespace freud::pmft
