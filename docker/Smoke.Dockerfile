FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential pkg-config bison flex git wget ca-certificates \
    libx11-dev libxext-dev libxrandr-dev libxinerama-dev libxcursor-dev libxft-dev \
    libasound2-dev libgl1-mesa-dev libfreetype6-dev xvfb && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . /src

# Build limbo directly with gcc (no makemk.sh)
RUN if [ -d /src/limbo ] && command -v gcc >/dev/null 2>&1; then \
      echo "Building limbo with gcc"; \
      cd /src/limbo && gcc -I/src/include -I/src/utils/include -o /src/limbo *.c || echo "limbo build failed"; \
    fi

# Build emu with make if Makefile exists
RUN if [ -d /src/emu ] && [ -f /src/emu/Makefile ]; then \
      echo "Building emu with make"; \
      cd /src/emu && make || echo "emu make failed"; \
    fi

ENV PATH="/src:/usr/local/bin:$PATH"

ENTRYPOINT ["/bin/bash","-lc"]
CMD ["echo smoke image ready"]
