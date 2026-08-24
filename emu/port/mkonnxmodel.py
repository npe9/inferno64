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
    main(sys.argv[1] if len(sys.argv) > 1 else "lib/ml/linear.onnx")
