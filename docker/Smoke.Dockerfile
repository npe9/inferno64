FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential pkg-config bison flex git wget ca-certificates \
    libx11-dev libxext-dev libxrandr-dev libxinerama-dev libxcursor-dev libxft-dev \
    libasound2-dev libgl1-mesa-dev libfreetype6-dev xvfb && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . /src

# Create a CI-friendly mkconfig so makemk.sh doesn't try to use developer paths
RUN printf 'ROOT=/src\nSYSHOST=Linux\nSYSTARG=Linux\nOBJTYPE=amd64\nSYSTYPE=posix\nCONF=emu-x11\n' > /src/mkconfig \
    && chmod +x /src/makemk.sh || true

# Try to bootstrap mk and build limbo (best-effort)
RUN /src/makemk.sh || true \
    && if [ -x /src/Linux/amd64/bin/mk ]; then PATH=/src/Linux/amd64/bin:$PATH mk -f /src/limbo/mkfile || true; else (cd /src/limbo && gcc -I/src/include -I/src/utils/include -o limbo *.c) || true; fi

# Try to build the emu (best-effort)
RUN if [ -x /src/Linux/amd64/bin/mk ]; then PATH=/src/Linux/amd64/bin:$PATH cd /src/emu && mk CONF=emu-x11 install || true; else (cd /src/emu && make || true); fi

ENV PATH="/src/Linux/amd64/bin:/usr/local/bin:$PATH"

ENTRYPOINT ["/bin/bash","-lc"]
CMD ["echo smoke image ready"]
