# Copyright (c) 2010-2020 The Regents of the University of Michigan
# This file is from the freud project, released under the BSD 3-Clause License.

from freud.util cimport vec3
from freud._locality cimport BondHistogramCompute
from libcpp cimport bool
from libcpp.vector cimport vector

cimport freud._box
cimport freud._locality
cimport freud.util

ctypedef unsigned int uint

cdef extern from "StaticStructureFactor.h" namespace "freud::diffraction":
    cdef cppclass StaticStructureFactor:
        StaticStructureFactor(uint, float, float, bool) except +
        void accumulate(const freud._locality.NeighborQuery*,
                        const vec3[float]*,
                        unsigned int) except +
        void reset()
        const freud.util.ManagedArray[float] &getStructureFactor()
        const vector[float] getBinEdges() const
        const vector[float] getBinCenters() const
        float &getMinValidK() const
