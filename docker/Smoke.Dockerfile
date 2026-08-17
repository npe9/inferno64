FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential pkg-config bison flex git wget ca-certificates \
    libx11-dev libxext-dev libxrandr-dev libxinerama-dev libxcursor-dev libxft-dev \
    libasound2-dev libgl1-mesa-dev libfreetype6-dev xvfb && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . /src

# Try to build limbo directly (gcc fallback) and emu (best-effort)
RUN printf 'ROOT=/src\nSYSHOST=Linux\nSYSTARG=Linux\nOBJTYPE=amd64\nSYSTYPE=posix\nCONF=emu-x11\n' > /src/mkconfig || true \
    && if command -v gcc >/dev/null 2>&1; then \
        if [ -d /src/limbo ]; then \
          echo "Building limbo with gcc"; \
          (cd /src/limbo && gcc -I/src/include -I/src/utils/include -o /src/limbo *.c) || true; \
        fi; \
    fi \
    && if [ -d /src/emu ]; then \
        echo "Attempting to build emu with make"; \
        (cd /src/emu && if [ -f Makefile ]; then make || true; else echo "no Makefile for emu"; fi) || true; \
    fi

ENV PATH="/src:/usr/local/bin:$PATH"

ENTRYPOINT ["/bin/bash","-lc"]
CMD ["echo smoke image ready"]
