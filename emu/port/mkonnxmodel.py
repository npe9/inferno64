#!/usr/bin/env python3
#
# Build the fixture model ml(3)'s tests run against: lib/ml/linear.onnx.
#
# Hand-chosen weights rather than a trained model, because a test has to be
# able to assert the answer:
#
#	y = Wx + b,   W = [[1, 2, 3], [10, 20, 30]],   b = [0.5, -0.5]
#
# so a row of (1,2,3) gives (14.5, 139.5). Those differ by an order of
# magnitude and neither is symmetric in its inputs, so a transposed weight
# matrix, a swapped output, a wrong element width or a byte-order mistake all
# produce a visibly wrong number rather than a plausible one. Those are the
# same weights the CoreML fixture used, so the two backends can be compared
# against the same arithmetic.
#
# The batch dimension is deliberately left symbolic. A model with every
# dimension fixed would not exercise the thing the ONNX backend exists for:
# ml(3) reports an open dimension as -1 and fills it in from the amount
# written, so this fixture is what proves a variable-length input works at
# all. Write three values and it is one row; write six and it is two.
#
# No dependencies. The CoreML generator this replaces needed coremltools and
# numpy, which meant the fixture could only be rebuilt on a machine that had
# them - and neither is installed on the machine this was written on. ONNX is
# protobuf, protobuf's wire format is half a page, so it is written out here
# directly and anyone can rebuild the fixture with a stock python.
#
import struct
import sys

# ---- protobuf wire format -------------------------------------------------


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def tag(field, wire):
    return varint((field << 3) | wire)


def vfield(field, n):                      # varint field
    return tag(field, 0) + varint(n)


def bfield(field, b):                      # length-delimited field
    if isinstance(b, str):
        b = b.encode()
    return tag(field, 2) + varint(len(b)) + b


# ---- the pieces of an ONNX model ------------------------------------------

FLOAT = 1                                  # TensorProto.DataType.FLOAT


def tensor(name, dims, values):
    """TensorProto: dims, data_type, name, raw_data."""
    b = b""
    for d in dims:                         # 1: dims, repeated int64
        b += vfield(1, d)
    b += vfield(2, FLOAT)                  # 2: data_type
    b += bfield(8, name)                   # 8: name
    b += bfield(9, struct.pack("<%df" % len(values), *values))   # 9: raw_data
    return b


def valueinfo(name, dims):
    """ValueInfoProto with a tensor type. A string in dims is a symbolic
    dimension - the thing this fixture exists to exercise."""
    shape = b""
    for d in dims:
        if isinstance(d, str):
            dim = bfield(2, d)             # Dimension.dim_param
        else:
            dim = vfield(1, d)             # Dimension.dim_value
        shape += bfield(1, dim)            # TensorShapeProto.dim
    ttensor = vfield(1, FLOAT) + bfield(2, shape)   # elem_type, shape
    ttype = bfield(1, ttensor)             # TypeProto.tensor_type
    return bfield(1, name) + bfield(2, ttype)


def node(op, inputs, outputs, name, attrs=b""):
    b = b""
    for i in inputs:
        b += bfield(1, i)
    for o in outputs:
        b += bfield(2, o)
    b += bfield(3, name) + bfield(4, op) + attrs
    return b


def attr_int(name, value):
    """AttributeProto: name, i, type=INT(2)."""
    return bfield(5, bfield(1, name) + vfield(3, value) + vfield(20, 2))


def attr_ints(name, values):
    """AttributeProto: name, ints, type=INTS(7)."""
    b = bfield(1, name)
    for v in values:
        b += vfield(8, v)
    return bfield(5, b + vfield(20, 7))


def mlp(out):
    """The second fixture: everything in the software backend's operator set
    that linear.onnx does not reach.

    linear.onnx is one Gemm. Agreeing with onnxruntime on one Gemm says
    nothing about broadcasting, Softmax, Transpose or Concat, and those are
    where a hand-written evaluator goes wrong - an axis off by one, a stride
    taken from the wrong shape, a broadcast that happens to be right when both
    operands are the same size.

    So this graph is shaped to reach them all, and to reach them in a way that
    a mistake cannot survive:

        h  = Gemm(x, W1, b1)      [batch,4] -> [batch,3]
        c  = Concat(Tanh(h), Relu(h), axis=1)          -> [batch,6]
        t  = Transpose(c, perm=[1,0])                  -> [6,batch]
        s  = Add(t, k)   k is [6,1], so it broadcasts over the batch
        y  = Softmax(Transpose(s, perm=[1,0]), axis=1) -> [batch,6]

    Tanh and Relu of the same h differ elementwise, so a Concat that swaps its
    operands or an axis mistake changes the answer. The Transpose pair is not
    a no-op, because the Add in between broadcasts along the axis the first
    Transpose moved: get either perm wrong and the bias lands on the batch
    instead of the feature. And Softmax makes every row sum to one, which is
    a property mltest can check with no oracle at all.

    There are no hand-computed expected values here. The point of this fixture
    is the comparison against onnxruntime, which is a real implementation of
    these operators; asserting numbers this file computed itself would only
    test that the file agrees with itself.
    """
    W1 = [ 0.5, -0.25, 0.125, 1.0,
          -1.5,  0.75, 0.25, -0.5,
           0.25, 0.5, -0.75,  0.125]        # 3x4, row major
    b1 = [0.1, -0.2, 0.3]
    k  = [0.0, 1.0, -1.0, 0.5, -0.5, 2.0]   # 6x1

    nodes = b""
    nodes += bfield(1, node("Gemm", ["x", "W1", "b1"], ["h"], "l1",
                            attr_int("transB", 1)))
    nodes += bfield(1, node("Tanh", ["h"], ["ht"], "act1"))
    nodes += bfield(1, node("Relu", ["h"], ["hr"], "act2"))
    nodes += bfield(1, node("Concat", ["ht", "hr"], ["c"], "cat",
                            attr_int("axis", 1)))
    nodes += bfield(1, node("Transpose", ["c"], ["t"], "tr1",
                            attr_ints("perm", [1, 0])))
    nodes += bfield(1, node("Add", ["t", "k"], ["s"], "bias"))
    nodes += bfield(1, node("Transpose", ["s"], ["u"], "tr2",
                            attr_ints("perm", [1, 0])))
    nodes += bfield(1, node("Softmax", ["u"], ["y"], "sm",
                            attr_int("axis", 1)))

    graph = nodes
    graph += bfield(2, "mlp")
    graph += bfield(5, tensor("W1", [3, 4], W1))
    graph += bfield(5, tensor("b1", [3], b1))
    graph += bfield(5, tensor("k", [6, 1], k))
    graph += bfield(11, valueinfo("x", ["batch", 4]))
    graph += bfield(12, valueinfo("y", ["batch", 6]))

    model = b""
    model += vfield(1, 7)
    model += bfield(2, "inferno mkonnxmodel")
    model += bfield(7, graph)
    model += bfield(8, bfield(1, "") + vfield(2, 13))

    with open(out, "wb") as f:
        f.write(model)
    print("wrote %s, %d bytes" % (out, len(model)))


def main(out):
    W = [1.0, 2.0, 3.0, 10.0, 20.0, 30.0]          # 2x3, row major
    bias = [0.5, -0.5]

    # Gemm with transB: Y = A * B' + C, A is [batch,3], B is [2,3], so
    # B' is [3,2] and Y is [batch,2]. Written this way round so the weights
    # are readable above as the rows they are.
    n = node("Gemm", ["x", "W", "b"], ["y"], "linear",
             attr_int("transB", 1))

    graph = b""
    graph += bfield(1, n)                          # 1: node
    graph += bfield(2, "linear")                   # 2: name
    graph += bfield(5, tensor("W", [2, 3], W))     # 5: initializer
    graph += bfield(5, tensor("b", [2], bias))
    graph += bfield(11, valueinfo("x", ["batch", 3]))   # 11: input
    graph += bfield(12, valueinfo("y", ["batch", 2]))   # 12: output

    model = b""
    model += vfield(1, 7)                          # 1: ir_version (7)
    model += bfield(2, "inferno mkonnxmodel")      # 2: producer_name
    model += bfield(7, graph)                      # 7: graph
    model += bfield(8, bfield(1, "") + vfield(2, 13))  # 8: opset ai.onnx v13

    with open(out, "wb") as f:
        f.write(model)
    print("wrote %s, %d bytes" % (out, len(model)))


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "linear"
    if which == "mlp":
        mlp(sys.argv[2] if len(sys.argv) > 2 else "lib/ml/mlp.onnx")
    else:
        main(sys.argv[2] if len(sys.argv) > 2 else "lib/ml/linear.onnx")
