#!/bin/bash
# © Copyright IBM Corporation 2020.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/OpenResty/1.17.8.2/build_openresty.sh
# Execute build script: bash build_openresty.sh    (provide -h for help)

set -e -o pipefail

PACKAGE_NAME="openresty"
PACKAGE_VERSION="1.17.8.2"
SOURCE_ROOT="$(pwd)"

FORCE="false"
LOG_FILE="$SOURCE_ROOT/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"
PATCH_URL="https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/OpenResty/1.17.8.2/patch"

trap cleanup 0 1 2 ERR

#Check if directory exists
if [ ! -d "$SOURCE_ROOT/logs/" ]; then
    mkdir -p "$SOURCE_ROOT/logs/"
fi

# Set the Distro ID
source "/etc/os-release"
	
function prepare() {
    if command -v "sudo" >/dev/null; then
        printf -- 'Sudo : Yes\n' >>"$LOG_FILE"
    else
        printf -- 'Sudo : No \n' >>"$LOG_FILE"
        printf -- 'You can install the same from installing sudo from repository using apt, yum or zypper based on your distro. \n'
        exit 1
    fi

    if [[ "$FORCE" == "true" ]]; then
        printf -- 'Force attribute provided hence continuing with install without confirmation message\n' |& tee -a "$LOG_FILE"
    else
        # Ask user for prerequisite installation
        printf -- "\nAs part of the installation , dependencies would be installed/upgraded.\n"
        while true; do
            read -r -p "Do you want to continue (y/n) ? :  " yn
            case $yn in
            [Yy]*)
                printf -- 'User responded with Yes. \n' >>"$LOG_FILE"
                break
                ;;
            [Nn]*) exit ;;
            *) echo "Please provide confirmation to proceed." ;;
            esac
        done
    fi
}

function cleanup() {
    # Remove artifacts
    rm -rf "$SOURCE_ROOT/openresty-${PACKAGE_VERSION}.tar.gz"
    rm -rf "$SOURCE_ROOT/openresty-${PACKAGE_VERSION}/t/Config.pm.diff"
    printf -- "Cleaned up the artifacts\n" >>"$LOG_FILE"
}

function configureAndInstall() {

    printf -- "Configuration and Installation started \n"
    
    if [[ "${DISTRO}" == "ubuntu-20.04" ]]; then
		cd $SOURCE_ROOT
		wget https://www.openssl.org/source/old/1.1.1/openssl-1.1.1d.tar.gz
		tar xvf openssl-1.1.1d.tar.gz
		cd openssl-1.1.1d
		./config --prefix=/usr/local --openssldir=/usr/local
		make
		sudo make install
		sudo ldconfig /usr/local/lib64
		echo ca-certificate=/etc/ssl/certs/ca-certificates.crt >> $HOME/.wgetrc
		export PATH=/usr/local/bin:$PATH
    fi
    #Download Source code
    export PATH=$PATH:/sbin
    cd $SOURCE_ROOT
    wget https://openresty.org/download/openresty-${PACKAGE_VERSION}.tar.gz
    tar -xvf openresty-${PACKAGE_VERSION}.tar.gz

    #Change the configure file for s390x
    sed -i '742,785s/.*/#&/;717,726s/.*/#&/' $SOURCE_ROOT/openresty-${PACKAGE_VERSION}/configure
        
    #Build and install OpenResty
    cd $SOURCE_ROOT/openresty-${PACKAGE_VERSION}
    ./configure --without-http_redis2_module --with-http_iconv_module --with-http_postgres_module
    make -j2
    sudo make install

    #Set Environment Variable
    export PATH=/usr/local/openresty/bin:$PATH
    sudo cp -r /usr/local/openresty/ /usr/local/bin

    #Run Tests
    runTest 
    
    printf -- "\n* OpenResty successfully installed *\n"
}

function runTest() {
    set +e
    if [[ "$TESTS" == "true" ]]; then    
        printf -- "TEST Flag is set, continue with running test \n"  >> "$LOG_FILE"
         
        export PATH=/usr/local/openresty/bin:$PATH
	export PATH=$PATH:/sbin

        #Install cpan modules        
        case "$DISTRO" in       
        "rhel"* | sles-12* | "ubuntu"*)
            sudo PERL_MM_USE_DEFAULT=1 cpan Cwd IO::Socket::SSL IPC::Run3 Test::Base Test::LongString 
            ;;
        "sles-15"*)
            sudo zypper install -y glibc-i18ndata glibc-locale
	    sudo localedef -i en_US -f UTF-8 en_US.UTF-8
	    sudo PERL_MM_USE_DEFAULT=1 cpan Cwd IO::Socket::SSL IPC::Run3 Test::Base Test::LongString
            ;;
        esac
            
        #Download files and modify to run sanity tests
        mkdir $SOURCE_ROOT/openresty-${PACKAGE_VERSION}/t
        cd $SOURCE_ROOT/openresty-${PACKAGE_VERSION}/t
        wget https://raw.githubusercontent.com/openresty/openresty/v${PACKAGE_VERSION}/t/Config.pm
        wget https://raw.githubusercontent.com/openresty/openresty/v${PACKAGE_VERSION}/t/000-sanity.t
	
	#Make changes to $SOURCE_ROOT/openresty-1.17.8.2/t/Config.pm
	curl -o "Config.pm.diff"  $PATCH_URL/Config.pm.diff
	patch -l $SOURCE_ROOT/openresty-${PACKAGE_VERSION}/t/Config.pm Config.pm.diff
	printf -- 'Updated openresty-${PACKAGE_VERSION}/t/Config.pm \n'
	
        cd $SOURCE_ROOT/openresty-${PACKAGE_VERSION}/t
        sed -i "/configure line 719/d" 000-sanity.t
        sed -i "/configure line 764/d" 000-sanity.t
        sed -i "/INFO: found -msse4.2 in cc./d" 000-sanity.t
        sed -i "/WARNING: -msse4.2/d" 000-sanity.t
        sed -i "s/ XCFLAGS='-msse4.2'//g" 000-sanity.t
        sed -i "s/ -msse4.2//g" 000-sanity.t
        sed -i "s/-msse4.2 -DLUAJIT_ENABLE_LUA52COMPAT/-DLUAJIT_ENABLE_LUA52COMPAT/g" 000-sanity.t

        printf -- 'Updated openresty-${PACKAGE_VERSION}/t/000-sanity.t \n'
		
        case "$DISTRO" in
        "sles-15"* | rhel-8* | "ubuntu-18.04" | "ubuntu-20.04") 
            export PERL5LIB=$SOURCE_ROOT/openresty-${PACKAGE_VERSION}
            ;;
        esac
        cd $SOURCE_ROOT/openresty-${PACKAGE_VERSION}
        prove -r t |& tee -a "$LOG_FILE"
    fi
    set -e
}
function logDetails() {
    printf -- '**************************** SYSTEM DETAILS *************************************************************\n' >>"$LOG_FILE"
    if [ -f "/etc/os-release" ]; then
        cat "/etc/os-release" >>"$LOG_FILE"
    fi

    cat /proc/version >>"$LOG_FILE"
    printf -- '*********************************************************************************************************\n' >>"$LOG_FILE"
    printf -- "Detected %s \n" "$PRETTY_NAME"
    printf -- "Request details : PACKAGE NAME= %s , VERSION= %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" |& tee -a "$LOG_FILE"
}

# Print the usage message
function printHelp() {
    echo
    echo "Usage: "
    echo " build_openresty.sh  [-d debug] [-y install-without-confirmation] [-t install-with-test]"
    echo
}

while getopts "h?dyt" opt; do
    case "$opt" in
    h | \?)
        printHelp
        exit 0
        ;;
    d)
        set -x
        ;;
    y)
        FORCE="true"
        ;;
    t)
	TESTS="true"
	;;
    esac
done

function gettingStarted() {
    	printf -- '\n********************************************************************************************************\n'
    	printf -- "*                     Getting Started                 * \n"
    	printf -- "         You have successfully installed OpenResty. \n"
	printf -- "         To Run OpenResty run the following commands :\n"
	printf -- "         export PATH=/usr/local/openresty/bin:\$PATH \n"
        printf -- "         resty -V\n"
        printf -- "         resty -e 'print(\"hello, world\")' \n"		    
    	printf -- '**********************************************************************************************************\n'
}

logDetails
prepare #Check Prequisites
DISTRO="$ID-$VERSION_ID"

case "$DISTRO" in
"ubuntu-18.04" | "ubuntu-20.04")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo apt-get update
    sudo apt-get install -y curl tar wget make gcc dos2unix libreadline-dev patch libpcre3-dev libpcre3 libcurl4-openssl-dev libncursesada*-dev postgresql libpq-dev openssl libssl-dev perl zlib1g zlib1g-dev |& tee -a "$LOG_FILE"
    sudo ln -s make /usr/bin/gmake
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
"rhel-7.6" | "rhel-7.7" | "rhel-8.1" | "rhel-8.2")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo yum install -y curl tar wget make gcc gcc-c++ unix2dos cpan perl postgresql-devel patch pcre-devel readline-devel openssl openssl-devel glibc-common |& tee -a "$LOG_FILE"
    export PATH=$PATH:/sbin
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;

"rhel-7.8")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo yum downgrade -y glibc glibc-common 
    sudo yum downgrade -y krb5-libs 
    sudo yum downgrade -y libss e2fsprogs-libs e2fsprogs libcom_err
    sudo yum downgrade -y libselinux-utils libselinux-python libselinux
    sudo yum install -y curl tar wget make gcc gcc-c++ unix2dos cpan perl postgresql-devel patch pcre-devel readline-devel openssl openssl-devel |& tee -a "$LOG_FILE"
    export PATH=$PATH:/sbin
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;

"sles-12.5")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo zypper install -y curl tar wget make gcc gcc-c++ dos2unix perl postgresql10-devel patch pcre-devel readline-devel openssl libopenssl-devel aaa_base |& tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
"sles-15.1" | "sles-15.2")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo zypper install -y curl tar wget make gcc gcc-c++ dos2unix python3-lxml python3-curses perl postgresql10-devel patch pcre-devel readline-devel openssl openssl-devel aaa_base gzip |& tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
*)
    printf -- "%s not supported \n" "$DISTRO" |& tee -a "$LOG_FILE"
    exit 1
    ;;
esac

gettingStarted |& tee -a "$LOG_FILE"
