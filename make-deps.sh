#!/bin/bash

# determine the root directory of the package repo

REPO_DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
if [ ! -d  "${REPO_DIR}/.git" ]; then
    2>&1 echo "${REPO_DIR} is not a git repository"
    exit 1
fi

if [ -z "${http_proxy}" ]; then
    2>&1 echo "http_proxy environment variable is not defined, but required"
    exit 1
fi

proxy=${http_proxy##http://}
proxy=${proxy%/}
proxy_host=$(echo $proxy | sed -e 's/:.*$//')
proxy_port=$(echo $proxy | sed -e 's/^.*://')

# the first and the only argument should be the version of kafka

NAME=$(basename ${BASH_SOURCE[0]})
if [ $# -ne 1 ]; then
    2>&1 cat <<EOF
Usage: $NAME <kafka version>
EOF
    exit 2
fi

KAFKA_VERSION=$1

### move previous repository temporarily

if [ -d ${HOME}/.gradle ]; then
    mv ${HOME}/.gradle ${HOME}/.gradle.backup.$$
fi

### fetch the kafka sources and unpack

KAFKA_TGZ=kafka-${KAFKA_VERSION}-src.tgz

if [ ! -f "${KAFKA_TGZ}" ]; then
    KAFKA_URL=http://apache.mirrors.lucidnetworks.net/kafka/${KAFKA_VERSION}/${KAFKA_TGZ}
    if ! curl -L -o "${KAFKA_TGZ}" "${KAFKA_URL}"; then
        2>&1 echo Failed to download sources: $KAFKA_URL
        exit 1
    fi
fi

cd "${REPO_DIR}"

# assume all the files go to a subdir (so any file will give us the directory
# it's extracted to)
KAFKA_DIR=$(tar xzvf "${KAFKA_TGZ}" | head -1)
KAFKA_DIR=${KAFKA_DIR%%/*}
tar xzf "${KAFKA_TGZ}"

### fetch the kafka depenencies and store the log (to retrieve the urls)

cd "${KAFKA_DIR}"

# patch it as per the kafka .spec (assume files do not contain spaces)
PATCHES=$(grep ^Patch "${REPO_DIR}/../apache-kafka/apache-kafka.spec" | sed -e 's/Patch[0-9]\+\s*:\s*\(\S\)\s*/\1/')

for p in $PATCHES; do
    patch -p1 < "${REPO_DIR}/../apache-kafka/${p}"
done

# configure the repositories explicitly (we will match for these URLs later in
# the script)
patch -p1 < "${REPO_DIR}/add-remote-repos.patch"

gradle -PscalaVersion=2.11 releaseTarGz -x signArchives                 \
        -Dhttp.proxyHost=${proxy_host} -Dhttp.proxyPort=${proxy_port}    \
        -Dhttps.proxyHost=${proxy_host} -Dhttps.proxyPort=${proxy_port}   \
        > kafka.build.out                                                  \
        || exit 1

# next, bring the test dependencies. the build may fail, but it's not critical
# (the apache-kafka.spec permits it too).
gradle -PscalaVersion=2.11 releaseTarGz -x signArchives                 \
        -Dhttp.proxyHost=${proxy_host} -Dhttp.proxyPort=${proxy_port}    \
        -Dhttps.proxyHost=${proxy_host} -Dhttps.proxyPort=${proxy_port}   \
        test >> kafka.build.out

cd "${REPO_DIR}"

# remove previously created artifacts
rm -f sources.txt install.txt files.txt metadata-*.patch

### make the list of the dependency urls
DEPENDENCIES=($(grep '^Download' "${KAFKA_DIR}/kafka.build.out" | sed -e 's/^Download\s\+//' | uniq))

### create pieces of the spec (SourceXXX definitions and their install actions)

# these are two repositories gradle is configured to use (explicitly via
# add-remote-repos.patch)
REPOSITORY_URLS=(
                https://repo1.maven.org/maven2/ 
                https://plugins.gradle.org/m2/
                )
# kafka specifically has some basename clashes which results download conflicts
# when used in .spec as-is. keep track of these files to name them differently.
declare -A FILE_MAP
SOURCES_SECTION=""
INSTALL_SECTION=""
FILES_SECTION=""
warn=
n=0

for dep in ${DEPENDENCIES[@]}; do
    dep_bn=$(basename "$dep")
    dep_sfx=""
    if [ -n "${FILE_MAP[${dep_bn}]}" ]; then
        let dep_sfx=${FILE_MAP[${dep_bn}]}+1
        FILE_MAP[${dep_bn}]=${dep_sfx}
    else
        FILE_MAP[${dep_bn}]=0
    fi
    for url in ${REPOSITORY_URLS[@]}; do
        dep_path=${dep##$url}
        # if we actually removed the url, then it's a mismatch (i.e. success)
        if [ "${dep_path}" != "${dep}" ]; then
            dep_url="${dep}"
            dep="${dep_path}"
            break
        fi
    done
    [ -z "$dep_url" ] && continue
    dep_dn=$(dirname "${dep_path}")
    dep_fn="${dep_bn}${dep_sfx}" # downloaded filename
    if [ -n "${dep_sfx}" ]; then
        dep_url="${dep_url}#/${dep_fn}"
    fi
    SOURCES_SECTION="${SOURCES_SECTION}
Source${n} : ${dep_url}"
    INSTALL_SECTION="${INSTALL_SECTION}
mkdir -p %{buildroot}/usr/share/apache-kafka/.m2/repository/${dep_dn}
cp %{SOURCE${n}} %{buildroot}/usr/share/apache-kafka/.m2/repository/${dep_dn}/${dep_bn}"
    FILES_SECTION="${FILES_SECTION}
/usr/share/apache-kafka/.m2/repository/${dep}"
    let n=${n}+1
done

cd "${REPO_DIR}"

echo "${SOURCES_SECTION}" | sed -e '1d' > sources.txt
echo "${INSTALL_SECTION}" | sed -e '1d' > install.txt
echo "${FILES_SECTION}" | sed -e '1d' > files.txt

cat <<EOF

sources.txt     contains SourceXXXX definitions for the spec file.
install.txt     contains %install section.
files.txt       contains the %files section.
EOF

# restore previous repo
rm -rf ${HOME}/.gradle
if [ -d ${HOME}/.gradle.backup.$$ ]; then
    mv ${HOME}/.gradle.backup.$$ ${HOME}/.gradle 
fi
# vim: si:noai:nocin:tw=80:sw=4:ts=4:et:nu
