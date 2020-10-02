# Copyright (c) 2010-2020 The Regents of the University of Michigan
# This file is from the freud project, released under the BSD 3-Clause License.

R"""
The :class:`freud.diffraction` module provides functions for computing the
diffraction pattern of particles in systems with long range order.

.. rubric:: Stability

:mod:`freud.diffraction` is **unstable**. When upgrading from version 2.x to
2.y (y > x), existing freud scripts may need to be updated. The API will be
finalized in a future release.
"""

import freud.locality
import logging
import numpy as np
import scipy.ndimage
import rowan

from cython.operator cimport dereference
from freud.util cimport vec3, _Compute
from freud.locality cimport _SpatialHistogram1D
from libcpp cimport bool as cbool

cimport freud._diffraction
cimport freud.locality
cimport freud.util
cimport numpy as np


logger = logging.getLogger(__name__)

cdef class StaticStructureFactor(_Compute):
    R"""Computes a 1D static structure factor.

    This computes the static `structure factor
    <https://en.wikipedia.org/wiki/Structure_factor>`__ :math:`S(k)`,
    assuming an isotropic system (averaging over all :math:`k` vectors of the
    same magnitude). This is implemented using the Debye scattering equation.
    This class offers a *direct* method and an *RDF Fourier Transform* method
    that is considerably faster but less accurate in some regimes (low values
    of :math:`k`). The direct method is computed as:

    .. math::

        S(k) = \frac{1}{N} \sum_{i=0}^{N} \sum_{j=0}^{N} \text{sinc}(k r_{ij})

    The RDF method is computed as:

    .. math::

        S(k) = 1 + 4 \pi \frac{N}{V} \int_0^R r^2 (g(r) - 1) \text{sinc}(k r)
        dr

    where :math:`N` is the number of particles, :math:`V` is the box volume,
    :math:`g(r)` is the radial distribution function, :math:`R` is the upper
    limit of the RDF (half of the minimum box side length) and the
    :math:`\text{sinc}` function is defined as :math:`\sin x / x` (no factor
    of :math:`\pi` as in some conventions).

    .. note::
        This code assumes all particles have a form factor :math:`f` of 1.

    This class is based on the MIT licensed `scattering library
    <https://github.com/mattwthompson/scattering/>`__ and literature references
    :cite:`Liu2016`.

    Args:
        bins (unsigned int):
            Number of bins in :math:`k` space.
        k_max (float):
            Maximum :math:`k` value to include in the calculation.
        k_min (float, optional):
            Minimum :math:`k` value include in the calculation. Note that
            there are practical restrictions on the validity of the
            calculation in the long-wavelength regime, see ``min_valid_k``
            (Default value = :code:`0`).
        direct (bool, optional):
            If ``True``, the structure factor is calculated by the *direct*
            method. By default, the *RDF Fourier Transform* method is used
            (Default value = :code:`False`).
    """
    cdef freud._diffraction.StaticStructureFactor * thisptr

    def __cinit__(self, unsigned int bins, float k_max, float k_min=0,
                  cbool direct=False):
        if type(self) == StaticStructureFactor:
            self.thisptr = new freud._diffraction.StaticStructureFactor(
                bins, k_max, k_min, direct)

    def __dealloc__(self):
        if type(self) == StaticStructureFactor:
            del self.thisptr

    def compute(self, system, query_points=None, reset=True):
        R"""Computes static structure factor.

        Args:
            system:
                Any object that is a valid argument to
                :class:`freud.locality.NeighborQuery.from_system`.
            query_points ((:math:`N_{query\_points}`, 3) :class:`numpy.ndarray`, optional):
                Query points used to calculate the structure factor. Uses the
                system's points if :code:`None` (Default value =
                :code:`None`).
            reset (bool):
                Whether to erase the previously computed values before adding
                the new computation; if False, will accumulate data (Default
                value: True).
        """  # noqa E501
        if reset:
            self._reset()

        cdef:
            freud.locality.NeighborQuery nq
            freud.locality.NeighborList nlist
            freud.locality._QueryArgs qargs
            const float[:, ::1] l_query_points
            unsigned int num_query_points

        # This is identical to _preprocess_arguments except with no
        # neighbors/qargs. The C++ class builds the largest allowed ball query
        # (r_max = L/2) if using the RDF method.
        nq = freud.locality.NeighborQuery.from_system(system)

        if query_points is None:
            query_points = nq.points
        else:
            query_points = freud.util._convert_array(
                query_points, shape=(None, 3))
        l_query_points = query_points
        num_query_points = l_query_points.shape[0]

        self.thisptr.accumulate(
            nq.get_ptr(),
            <vec3[float]*> &l_query_points[0, 0],
            num_query_points)
        return self

    def _reset(self):
        # Resets the values of StaticStructureFactor in memory.
        self.thisptr.reset()

    @property
    def bin_centers(self):
        """:class:`numpy.ndarray`: The centers of each bin of :math:`k`."""
        return np.array(self.thisptr.getBinCenters(), copy=True)

    @property
    def bin_edges(self):
        """:class:`numpy.ndarray`: The edges of each bin of :math:`k`."""
        return np.array(self.thisptr.getBinEdges(), copy=True)

    @property
    def bounds(self):
        """:class:`tuple`: A list of tuples indicating upper and lower bounds
        of the histogram."""
        bin_edges = self.bin_edges
        return (bin_edges[0], bin_edges[len(bin_edges)])

    @property
    def nbins(self):
        """int: The number of bins in the histogram."""
        return len(self.bin_centers)

    @property
    def k_max(self):
        """float: Maximum value of k at which to calculate the structure
        factor."""
        return self.bounds[1]

    @property
    def k_min(self):
        """float: Minimum value of k at which to calculate the structure
        factor."""
        return self.bounds[0]

    @_Compute._computed_property
    def min_valid_k(self):
        """float: Minimum valid value of k for the computed system box, equal
        to :math:`2\\pi/(L/2)` where :math:`L` is the minimum side length."""
        return self.thisptr.getMinValidK()

    @_Compute._computed_property
    def S_k(self):
        """(:math:`N_{bins}`,) :class:`numpy.ndarray`: Static
        structure factor :math:`S(k)` values."""
        return freud.util.make_managed_numpy_array(
            &self.thisptr.getStructureFactor(),
            freud.util.arr_type_t.FLOAT)

    def plot(self, ax=None, **kwargs):
        """Plot static structure factor.

        Args:
            ax (:class:`matplotlib.axes.Axes`, optional): Axis to plot on. If
                :code:`None`, make a new figure and axis.
                (Default value = :code:`None`)

        Returns:
            (:class:`matplotlib.axes.Axes`): Axis with the plot.
        """
        import freud.plot
        return freud.plot.line_plot(self.bin_edges[:len(self.bin_edges)-1],
                                    self.S_k,
                                    title="Static Structure Factor",
                                    xlabel=r"$k$",
                                    ylabel=r"$S(k)$",
                                    ax=ax)

    def _repr_png_(self):
        try:
            import freud.plot
            return freud.plot._ax_to_bytes(self.plot())
        except (AttributeError, ImportError):
            return None


cdef class DiffractionPattern(_Compute):
    R"""Computes a 2D diffraction pattern.

    The diffraction image represents the scattering of incident radiation,
    and is useful for identifying translational and/or rotational symmetry
    present in the system. This class computes the static `structure factor
    <https://en.wikipedia.org/wiki/Structure_factor>`__ :math:`S(\vec{k})` for
    a plane of wavevectors :math:`\vec{k}` orthogonal to a view axis. The
    view orientation :math:`(1, 0, 0, 0)` defaults to looking down the
    :math:`z` axis (at the :math:`xy` plane). The points in the system are
    converted to fractional coordinates, then binned into a grid whose
    resolution is given by ``grid_size``. A higher ``grid_size`` will lead to
    a higher resolution. The points are convolved with a Gaussian of width
    :math:`\sigma`, given by ``peak_width``. This convolution is performed
    as a multiplication in Fourier space. The computed diffraction pattern
    can be accessed as a square array of shape ``(output_size, output_size)``.

    This method is based on the implementations in the open-source
    `GIXStapose application <https://github.com/cmelab/GIXStapose>`_ and its
    predecessor, diffractometer :cite:`Jankowski2017`.

    Args:
        grid_size (unsigned int):
            Resolution of the diffraction grid (Default value = 512).
        output_size (unsigned int):
            Resolution of the output diffraction image, uses ``grid_size`` if
            not provided or ``None`` (Default value = :code:`None`).
    """
    cdef int _grid_size
    cdef int _output_size
    cdef double[:] _k_values_orig
    cdef double[:, :, :] _k_vectors_orig
    cdef double[:] _k_values
    cdef double[:, :, :] _k_vectors
    cdef double[:, :] _diffraction
    cdef double _box_matrix_scale_factor
    cdef double[:] _view_orientation
    cdef cbool _k_values_cached
    cdef cbool _k_vectors_cached

    def __init__(self, grid_size=512, output_size=None):
        self._grid_size = int(grid_size)
        self._output_size = int(grid_size) if output_size is None \
            else int(output_size)

        # Cache these because they are system-independent.
        self._k_values_orig = np.empty(self.output_size)
        self._k_vectors_orig = np.empty((
            self.output_size, self.output_size, 3))

        # Store these computed arrays which are exposed as properties.
        self._k_values = np.empty_like(self._k_values_orig)
        self._k_vectors = np.empty_like(self._k_vectors_orig)
        self._diffraction = np.empty((self.output_size, self.output_size))

    def _calc_proj(self, view_orientation, box):
        """Calculate the inverse shear matrix from finding the projected box
        vectors whose area of parallogram is the largest.

        Args:
            view_orientation ((:math:`4`) :class:`numpy.ndarray`):
                View orientation as a quaternion.
            box (:class:`~.box.Box`):
                Simulation box.

        Returns:
            (2, 2) :class:`numpy.ndarray`:
                Inverse shear matrix.
        """
        # Rotate the box matrix by the view orientation.
        box_matrix = rowan.rotate(view_orientation, box.to_matrix())

        # Compute normals for each box face.
        # The area of the face is the length of the vector.
        box_face_normals = np.cross(
            np.roll(box_matrix, 1, axis=-1),
            np.roll(box_matrix, -1, axis=-1),
            axis=0)

        # Compute view axis projections.
        projections = np.abs(box_face_normals.T @ np.array([0., 0., 1.]))

        # Determine the largest projection area along the view axis and use
        # that face for the projection into 2D.
        best_projection_axis = np.argmax(projections)
        secondary_axes = np.array([
            best_projection_axis + 1, best_projection_axis + 2]) % 3

        # Figure out appropriate shear matrix
        shear = box_matrix[np.ix_([0, 1], secondary_axes)]

        # Return the inverse shear matrix
        inv_shear = np.linalg.inv(shear)
        return inv_shear

    def _transform(self, img, box, inv_shear, zoom):
        """Zoom, shear, and scale diffraction intensities.

        Args:
            img ((``grid_size//zoom, grid_size//zoom``) :class:`numpy.ndarray`):
                Array of diffraction intensities.
            box (:class:`~.box.Box`):
                Simulation box.
            inv_shear ((2, 2) :class:`numpy.ndarray`):
                Inverse shear matrix.
            zoom (float):
                Scaling factor for incident wavevectors.

        Returns:
            (``output_size, output_size``) :class:`numpy.ndarray`:
                Transformed array of diffraction intensities.
        """  # noqa: E501

        # The adjustments to roll and roll_shift ensure that the peak
        # corresponding to k=0 is located at exactly
        # (output_size//2, output_size//2), regardless of whether the grid_size
        # and output_size are odd or even.

        roll = img.shape[0] / 2
        if img.shape[0] % 2 == 1:
            roll -= 0.5

        roll_shift = self.output_size / zoom / 2
        if self.output_size % 2 == 1:
            roll_shift -= 0.5 / zoom

        box_matrix = box.to_matrix()
        ss = np.max(box_matrix) * inv_shear

        shift_matrix = np.array(
            [[1, 0, -roll],
             [0, 1, -roll],
             [0, 0, 1]])

        # Translation for [roll_shift, roll_shift]
        # Then shift using ss
        shear_matrix = np.array(
            [[ss[1, 0], ss[0, 0], roll_shift],
             [ss[1, 1], ss[0, 1], roll_shift],
             [0, 0, 1]])

        zoom_matrix = np.diag((zoom, zoom, 1))

        # This matrix uses homogeneous coordinates. It is a 3x3 matrix that
        # transforms 2D points and adds an offset.
        inverse_transform = np.linalg.inv(
            zoom_matrix @ shear_matrix @ shift_matrix)

        img = scipy.ndimage.affine_transform(
            input=img,
            matrix=inverse_transform,
            output_shape=(self.output_size, self.output_size),
            order=1,
            mode="constant")
        return img

    def compute(self, system, view_orientation=None, zoom=4, peak_width=1):
        R"""Computes diffraction pattern.

        Args:
            system:
                Any object that is a valid argument to
                :class:`freud.locality.NeighborQuery.from_system`.
            view_orientation ((:math:`4`) :class:`numpy.ndarray`, optional):
                View orientation. Uses :math:`(1, 0, 0, 0)` if not provided
                or :code:`None` (Default value = :code:`None`).
            zoom (float):
                Scaling factor for incident wavevectors (Default value = 4).
            peak_width (float):
                Width of Gaussian convolved with points, in system length units
                (Default value = 1).
        """
        system = freud.locality.NeighborQuery.from_system(system)

        if view_orientation is None:
            view_orientation = np.array([1., 0., 0., 0.])
        view_orientation = freud.util._convert_array(
            view_orientation, (4,), np.double)

        grid_size = int(self.grid_size / zoom)

        # Compute the box projection matrix
        inv_shear = self._calc_proj(view_orientation, system.box)

        # Rotate points by the view quaternion and shear by the box projection
        xy = rowan.rotate(view_orientation, system.points)[:, 0:2]
        xy = xy @ inv_shear.T

        # Map positions to [0, 1] and compute a histogram "image"
        # Use grid_size+1 bin edges so that there are grid_size bins
        xy += 0.5
        xy %= 1
        im, _, _ = np.histogram2d(
            xy[:, 0], xy[:, 1], bins=np.linspace(0, 1, grid_size+1))

        # Compute FFT and convolve with Gaussian
        cdef double complex[:, :] diffraction_fft
        diffraction_fft = np.fft.fft2(im)
        diffraction_fft = scipy.ndimage.fourier.fourier_gaussian(
            diffraction_fft, peak_width / zoom)
        diffraction_fft = np.fft.fftshift(diffraction_fft)

        # Compute the squared modulus of the FFT, which is S(k)
        self._diffraction = np.real(
            diffraction_fft * np.conjugate(diffraction_fft))

        # Transform the image (scale, shear, zoom) and normalize S(k) by N^2
        N = len(system.points)
        self._diffraction = self._transform(
            self._diffraction, system.box, inv_shear, zoom) / (N*N)

        # Compute a cached array of k-vectors that can be rotated and scaled
        if not self._called_compute:
            # Create a 1D axis of k-vector magnitudes
            self._k_values_orig = np.fft.fftshift(np.fft.fftfreq(
                n=self.output_size,
                d=1/self.output_size))

            # Create a 3D meshgrid of k-vectors with shape
            # (output_size, output_size, 3)
            self._k_vectors_orig = np.asarray(np.meshgrid(
                self._k_values_orig, self._k_values_orig, [0])).T[0]

        # Cache the view orientation and box matrix scale factor for
        # lazy evaluation of k-values and k-vectors
        self._box_matrix_scale_factor = np.max(system.box.to_matrix())
        self._view_orientation = view_orientation
        self._k_values_cached = False
        self._k_vectors_cached = False

        return self

    @property
    def grid_size(self):
        """int: Resolution of the diffraction grid."""
        return self._grid_size

    @property
    def output_size(self):
        """int: Resolution of the output diffraction image."""
        return self._output_size

    @_Compute._computed_property
    def diffraction(self):
        """
        (``output_size``, ``output_size``) :class:`numpy.ndarray`:
            diffraction pattern.
        """
        return np.asarray(self._diffraction)

    @_Compute._computed_property
    def k_values(self):
        """(``output_size``, ) :class:`numpy.ndarray`: k-values."""
        if not self._k_values_cached:
            self._k_values = np.asarray(
                self._k_values_orig) / self._box_matrix_scale_factor
            self._k_values_cached = True
        return np.asarray(self._k_values)

    @_Compute._computed_property
    def k_vectors(self):
        """
        (``output_size``, ``output_size``, 3) :class:`numpy.ndarray`:
            k-vectors.
        """
        if not self._k_vectors_cached:
            self._k_vectors = rowan.rotate(
                self._view_orientation,
                self._k_vectors_orig) / self._box_matrix_scale_factor
            self._k_vectors_cached = True
        return np.asarray(self._k_vectors)

    def __repr__(self):
        return ("freud.diffraction.{cls}(grid_size={grid_size}, "
                "output_size={output_size})").format(
                    cls=type(self).__name__,
                    grid_size=self.grid_size,
                    output_size=self.output_size)

    def to_image(self, cmap='afmhot', vmin=4e-6, vmax=0.7):
        """Generates image of diffraction pattern.

        Args:
            cmap (str):
                Colormap name to use (Default value = :code:`'afmhot'`).
            vmin (float):
                Minimum of the color scale (Default value = 4e-6).
            vmax (float):
                Maximum of the color scale (Default value = 0.7).

        Returns:
            ((output_size, output_size, 4) :class:`numpy.ndarray`):
                RGBA array of pixels.
        """
        import matplotlib.cm
        import matplotlib.colors
        norm = matplotlib.colors.LogNorm(vmin=vmin, vmax=vmax)
        cmap = matplotlib.cm.get_cmap(cmap)
        image = cmap(norm(np.clip(self.diffraction, vmin, vmax)))
        return (image * 255).astype(np.uint8)

    def plot(self, ax=None, cmap='afmhot', vmin=4e-6, vmax=0.7):
        """Plot Diffraction Pattern.

        Args:
            ax (:class:`matplotlib.axes.Axes`, optional): Axis to plot on. If
                :code:`None`, make a new figure and axis.
                (Default value = :code:`None`)
            cmap (str):
                Colormap name to use (Default value = :code:`'afmhot'`).
            vmin (float):
                Minimum of the color scale (Default value = 4e-6).
            vmax (float):
                Maximum of the color scale (Default value = 0.7).

        Returns:
            (:class:`matplotlib.axes.Axes`): Axis with the plot.
        """
        import freud.plot
        return freud.plot.diffraction_plot(
            self.diffraction, self.k_values, ax, cmap, vmin, vmax)

    def _repr_png_(self):
        try:
            import freud.plot
            return freud.plot._ax_to_bytes(self.plot())
        except (AttributeError, ImportError):
            return None
