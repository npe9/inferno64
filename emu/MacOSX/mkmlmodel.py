#!/usr/bin/env python3
#
# Build the fixture model ml(3)'s tests run against: lib/ml/linear.mlmodel,
# a single fully-connected layer with weights chosen by hand.
#
# Hand-chosen weights rather than a trained model, because a test has to be
# able to assert the answer. y = Wx + b with
#
#	W = [[1, 2, 3], [10, 20, 30]]   b = [0.5, -0.5]
#
# so x = (1,2,3) gives y = (14.5, 139.5). Those differ by an order of
# magnitude and neither is symmetric in its inputs, so a transposed weight
# matrix, a swapped output or an off-by-one index all produce a visibly wrong
# number rather than a plausible one. Both are exactly representable in fp16,
# which matters because the ANE is fp16 and a value that merely rounds well
# would make the precision question untestable.
#
# Needs coremltools, which is not part of this tree:
#	python3 -m venv /tmp/v && /tmp/v/bin/pip install coremltools
#	/tmp/v/bin/python emu/MacOSX/mkmlmodel.py lib/ml/linear.mlmodel
#
import sys
import numpy as np
from coremltools.models import MLModel, datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder

Nin, Nout = 3, 2
W = np.array([[1.0, 2.0, 3.0], [10.0, 20.0, 30.0]], dtype=np.float32)
B = np.array([0.5, -0.5], dtype=np.float32)


def main(out):
    inputs = [("x", datatypes.Array(Nin))]
    outputs = [("y", datatypes.Array(Nout))]
    b = NeuralNetworkBuilder(inputs, outputs)
    b.add_inner_product(
        name="linear",
        W=W,
        b=B,
        input_channels=Nin,
        output_channels=Nout,
        has_bias=True,
        input_name="x",
        output_name="y",
    )
    spec = b.spec
    spec.description.metadata.shortDescription = (
        "y = Wx + b, W = [[1,2,3],[10,20,30]], b = [0.5,-0.5]; "
        "x = (1,2,3) gives y = (14.5, 139.5)"
    )
    MLModel(spec).save(out)

    # Check it here if CoreML can be reached from Python, rather than trusting
    # the builder: if the fixture is wrong, every test written against it is
    # wrong in the same direction. coremltools can only predict when its
    # Python happens to have the CoreML bindings - it does not on 3.14 - so
    # this is a bonus and not the real check. The real check is mlcaps,
    # alongside this file, which runs the model the way ml(3) does.
    want = W @ np.array([1.0, 2.0, 3.0], dtype=np.float32) + B
    try:
        got = MLModel(out).predict({"x": np.array([1.0, 2.0, 3.0], dtype=np.float32)})["y"]
    except Exception as e:
        print("wrote %s: %d -> %d inner product, expect y=%s" % (out, Nin, Nout, want))
        print("  not verified here (%s); run mlcaps to check it" % type(e).__name__)
        return 0
    if not np.allclose(got, want, atol=1e-4):
        print("mkmlmodel: model computes %s, expected %s" % (got, want), file=sys.stderr)
        return 1
    print("wrote %s: %d -> %d inner product, x=(1,2,3) gives y=%s" % (out, Nin, Nout, got))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "linear.mlmodel"))
