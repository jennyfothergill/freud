from __future__ import division

import numpy as np
import numpy.testing as npt
import freud.msd
import unittest


class TestMSD(unittest.TestCase):

    def test_MSD(self):
        """Test correct behavior for various constructor signatures"""
        positions = np.array([[[1, 0, 0]]])
        msd = freud.msd.MSD()
        msd_direct = freud.msd.MSD(mode='direct')
        self.assertTrue(msd.accumulate(positions).msd == [0])
        self.assertTrue(msd_direct.accumulate(positions).msd == [0])

        positions = positions.repeat(10, axis=0)
        npt.assert_allclose(msd.compute(positions).msd, 0, atol=1e-4)
        npt.assert_allclose(msd_direct.compute(positions).msd, 0, atol=1e-4)

        positions[:, 0, 0] = np.arange(10)
        npt.assert_allclose(
            msd.compute(positions).msd, np.arange(10)**2, atol=1e-4)
        npt.assert_allclose(
            msd_direct.compute(positions).msd, np.arange(10)**2)

        positions = positions.repeat(2, axis=1)
        positions[:, 1, :] = 0
        npt.assert_allclose(
            msd.compute(positions).msd, np.arange(10)**2/2, atol=1e-4)
        npt.assert_allclose(
            msd_direct.compute(positions).msd, np.arange(10)**2/2)

        # Test accumulation
        positions.flags['WRITEABLE'] = False
        msd.reset()
        msd.accumulate(positions[:, [0], :])
        msd.accumulate(positions[:, [1], :])
        npt.assert_allclose(
            msd.msd, msd.compute(positions).msd)

        # Test on a lot of random data against a more naive MSD calculation.
        def simple_msd(positions):
            """A naive MSD calculation, used to test."""
            msds = []

            for m in np.arange(positions.shape[0]):
                if m:
                    diffs = positions[:-m, :, :] - positions[m:, :, :]
                else:
                    diffs = np.zeros_like(positions)
                sqdist = np.square(diffs).sum(axis=2)
                msds.append(sqdist.mean(axis=0))

            return np.array(msds).mean(axis=1)

        num_tests = 5
        np.random.seed(10)
        for _ in range(num_tests):
            positions = np.random.rand(10, 10, 3)
            simple = simple_msd(positions)
            solution = msd.compute(positions).msd
            npt.assert_allclose(solution, simple, atol=1e-6)
            msd.reset()


if __name__ == '__main__':
    unittest.main()
