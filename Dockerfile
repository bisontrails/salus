FROM ruby:2.7.0@sha256:10f418593f7a95a50bdb880fdf94182c9c577b0b48159860dfb6854bebe0a41e
MAINTAINER security@coinbase.com

RUN apt-get update && apt-get upgrade -y --no-install-recommends && apt-get install -y --no-install-recommends \
    g++ \
    gcc \
    libc6-dev \
    make \
    pkg-config \
    curl \
    git  \
    python \
    python3 \
    python-pip \
    python3-pip \
    python-setuptools \
    python3-setuptools \
    python-dev \
    python3-dev \
    libpython-dev \
    libpython3-dev \
    libicu-dev \
    cmake \
    pkg-config \
    wget \
  && rm -rf /var/lib/apt/lists/*

# Required so that Brakeman doesn't run into encoding
# issues when it parses non-ASCII characters.
ENV LANG C.UTF-8
ENV LC_ALL C.UTF-8

### JS + NODE
ENV NODE_VERSION 13.8.0
ENV NPM_VERSION 6.13.7
ENV YARN_VERSION 1.22.0
ENV NPM_CONFIG_LOGLEVEL info

# Downloaded from https://nodejs.org/en/download/
# Replace file if node js upgrade
COPY node_SHASUMS256.txt SHASUMS256.txt

RUN curl -SLO "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz" \
  && grep " node-v$NODE_VERSION-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c -         \
  && tar -xJf "node-v$NODE_VERSION-linux-x64.tar.xz" -C /usr/local --strip-components=1     \
  && rm "node-v$NODE_VERSION-linux-x64.tar.xz" SHASUMS256.txt                               \
  && npm install -g npm@$NPM_VERSION                                                        \
  && npm install -g yarn@$YARN_VERSION

### GO - required for sift and gosec
ENV GO111MODULE on
ENV GOLANG_VERSION 1.13.7
ENV GOLANG_DOWNLOAD_URL https://golang.org/dl/go$GOLANG_VERSION.linux-amd64.tar.gz
ENV GOLANG_DOWNLOAD_SHA256 b3dd4bd781a0271b33168e627f7f43886b4c5d1c794a4015abf34e99c6526ca3
ENV SIFT_VERSION v0.9.0
ENV GOSEC_VERSION 2.3.0

RUN curl -fsSL "$GOLANG_DOWNLOAD_URL" -o golang.tar.gz \
  && echo "$GOLANG_DOWNLOAD_SHA256  golang.tar.gz" | sha256sum -c - \
  && tar -C /usr/local -xzf golang.tar.gz \
  && rm golang.tar.gz \
  && mv /usr/local/go/bin/go /usr/bin/

RUN go get github.com/svent/sift@$SIFT_VERSION \
  && mv /root/go/bin/sift /usr/bin/

RUN curl -sfL https://raw.githubusercontent.com/securego/gosec/master/install.sh | sh -s -- -b /usr/bin v$GOSEC_VERSION

### semgrep tool install https://semgrep.dev
ENV SEMGREP_VERSION 0.10.1
ENV SEMGREP_TARBALL_FILE semgrep-v$SEMGREP_VERSION-ubuntu-16.04.tgz
ENV SEMGREP_DOWNLOAD_URL https://github.com/returntocorp/semgrep/releases/download/v$SEMGREP_VERSION/$SEMGREP_TARBALL_FILE
ENV SEMGREP_DOWNLOAD_SHA256 7d07d223e88d52a2e8886e748726e1c8488d8d81ced34b80b128c362d9b57a0a

RUN curl -fsSL "$SEMGREP_DOWNLOAD_URL" -o semgrep.tar.gz \
  && echo "$SEMGREP_DOWNLOAD_SHA256 semgrep.tar.gz" | sha256sum -c - \
  && tar -C /usr/local/lib -xzf semgrep.tar.gz \
  && rm semgrep.tar.gz \
  && ln -sf /usr/local/lib/semgrep-files/semgrep /usr/local/bin/semgrep \
  && ln -sf /usr/local/lib/semgrep-files/semgrep-core /usr/local/bin/semgrep-core

### Salus

# make the folder for the repo (volumed in)
RUN mkdir -p /home/repo
WORKDIR /home

# make sure we're on latest bundler
RUN gem install bundler -v'2.0.2'

# ruby gems
COPY Gemfile Gemfile.lock /home/
RUN gem update --system
RUN bundle install --deployment --without development:test

# node modules
COPY package.json yarn.lock /home/
RUN yarn

# prime the bundler-audit CVE DB
RUN bundle exec bundle-audit update

# install wheel, needed by bandit
RUN pip install wheel
RUN pip3 install wheel

# Install bandit, python static code scanner
RUN pip install bandit==1.6.2
RUN mv /usr/local/bin/bandit /usr/local/bin/bandit2
RUN pip3 install bandit==1.6.2

# copy salus code
COPY bin /home/bin
COPY lib /home/lib
COPY salus-default.yaml /home/

# run the salus scan when this docker container is run
ENTRYPOINT ["bundle", "exec", "./bin/salus", "scan"]
