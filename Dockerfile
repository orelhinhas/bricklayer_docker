FROM orelhinhas/debian
MAINTAINER Joao Lisanti <jglisanti@gmail.com>

# Local variables
ENV PYTHONPATH "."
# Change to your server name
ENV SERVER_NAME bricklayer.snowwhite

### CHANGE PASSWORD BELOW ###
ENV REPO_FTP_PASSWD lerolero
### CHANGE PASSWORD ABOVE ###

# Install dependencies for bricklayer and build cyclone
RUN echo "deb-src http://http.debian.net/debian wheezy main" >> /etc/apt/sources.list
RUN apt-get update
RUN apt-get -y install build-essential devscripts cdbs python-twisted python-setuptools python-simplejson redis-server git python-yaml python-redis cdebootstrap ruby1.9.1-dev schroot supervisor telnet net-tools vim reprepro incron
RUN apt-get -y install apache2 apache2-mpm-worker apache2-utils apache2.2-bin apache2.2-common libapache2-mod-proxy-html
RUN apt-get -y install libxslt-dev libxml2-dev libqt4-dev bundler
RUN mkdir -p /var/log/supervisor
RUN mkdir /tmp/install_pkgs/ && \
    cd /tmp/install_pkgs && \
    git clone https://github.com/fiorix/cyclone.git && \
    cd cyclone && \
    touch README.rst && \
    dpkg-buildpackage -rfakeroot && \
    dpkg -i ../python-cyclone_*.deb

# Install and configure FTP Server
RUN apt-get -y install libpam-dev libcap2-dev libldap2-dev libmysqlclient-dev libmysqlclient15-dev libpq-dev libssl-dev
RUN apt-get -y install openbsd-inetd
RUN apt-get -y build-dep pure-ftpd pure-ftpd-common nmap
RUN cd /tmp/install_pkgs && \
    apt-get -y source pure-ftpd && \
    cd pure-ftpd-* && \
    sed -i '/^optflags=/ s/$/ --without-capabilities/g' ./debian/rules && \
    dpkg-buildpackage -b -uc && \
    dpkg -i ../pure-ftpd-common*.deb && \
    dpkg -i ../pure-ftpd_*.deb && \
    groupadd ftp && \
    useradd -g ftp -d /home/ftp -s /etc ftp 
RUN ["/bin/bash", "-c", "mkdir -p /home/ftp/{stable,testing,unstable}"]
RUN /bin/echo -e "$REPO_FTP_PASSWD\n$REPO_FTP_PASSWD"|pure-pw useradd repo -u ftp -g ftp -d /home/ftp
RUN pure-pw mkdb
RUN chown -R ftp:ftp /home/ftp

# Build Bricklayer
RUN cd /tmp/install_pkgs && \
    git clone https://github.com/locaweb/bricklayer.git && \
    cd bricklayer && \
    dpkg-buildpackage -rfakeroot && \
    dpkg -i ../bricklayer_*.deb

# Configure Apache and repository
RUN a2enmod proxy proxy_html proxy_http
RUN a2dissite default
ADD bricklayer_apache_vhost /etc/apache2/sites-available/bricklayer
ADD repository_apache_vhost /etc/apache2/sites-available/000-repository
RUN sed -i 's/localhost.localdomain/'"$SERVER_NAME"'/g' /etc/apache2/sites-available/bricklayer
RUN a2ensite bricklayer
RUN a2ensite 000-repository
RUN mkdir -p /var/lib/bricklayer/workspace/log
RUN chmod -R 700 /var/lib/bricklayer/workspace/log
ADD services.conf /etc/supervisor/conf.d/services.conf
RUN mkdir -p /var/www/packages/conf
ADD distributions /var/www/packages/conf/distributions
RUN ["/bin/bash", "-c", "touch /var/www/packages/conf/{options,override.{stable,testing,unstable}}"]
RUN /bin/echo -e "verbose\nbasedir ." >> /var/www/packages/conf/options

# Configure Redis for supervisord
RUN sed -i 's/daemonize yes/daemonize no/g' /etc/redis/redis.conf
RUN sed -i 's/bind 127.0.0.1/#bind 127.0.0.1/g' /etc/redis/redis.conf

# Configure Incron
RUN echo "root" > /etc/incron.allow && \
    echo "/home/ftp/stable IN_CREATE /var/www/packages/stable.sh" > /tmp/incrontab.rules && \
    echo "/home/ftp/testing IN_CREATE /var/www/packages/testing.sh" >> /tmp/incrontab.rules && \
    echo "/home/ftp/unstable IN_CREATE /var/www/packages/unstable.sh" >> /tmp/incrontab.rules && \
    incrontab /tmp/incrontab.rules

# Reprepro scripts
RUN echo "#!/bin/bash" > /var/www/packages/stable.sh && \
    echo "HOME='/home/ftp'" >> /var/www/packages/stable.sh && \
    echo "RELEASE='stable'" >> /var/www/packages/stable.sh && \
    echo "for PACKAGES in \`ls \$HOME/\$RELEASE/*.deb\`" >> /var/www/packages/stable.sh && \
    echo "do" >> /var/www/packages/stable.sh && \
    echo "  reprepro -b /var/www/packages includedeb \$RELEASE \$PACKAGES" >> /var/www/packages/stable.sh && \
    echo "done" >> /var/www/packages/stable.sh  && \
    chmod +x /var/www/packages/stable.sh

RUN echo "#!/bin/bash" > /var/www/packages/testing.sh && \
    echo "HOME='/home/ftp'" >> /var/www/packages/testing.sh && \
    echo "RELEASE='testing'" >> /var/www/packages/testing.sh && \
    echo "for PACKAGES in \`ls \$HOME/\$RELEASE/*.deb\`" >> /var/www/packages/testing.sh && \
    echo "do" >> /var/www/packages/testing.sh && \
    echo "  reprepro -b /var/www/packages includedeb \$RELEASE \$PACKAGES" >> /var/www/packages/testing.sh && \
    echo "done" >> /var/www/packages/testing.sh && \
    chmod +x /var/www/packages/testing.sh

RUN echo "#!/bin/bash" > /var/www/packages/unstable.sh && \
    echo "HOME='/home/ftp'" >> /var/www/packages/unstable.sh && \
    echo "RELEASE='unstable'" >> /var/www/packages/unstable.sh && \
    echo "for PACKAGES in \`ls \$HOME/\$RELEASE/*.deb\`" >> /var/www/packages/unstable.sh && \
    echo "do" >> /var/www/packages/unstable.sh && \
    echo "  reprepro -b /var/www/packages includedeb \$RELEASE \$PACKAGES" >> /var/www/packages/unstable.sh && \
    echo "done" >> /var/www/packages/unstable.sh && \
    chmod +x /var/www/packages/unstable.sh

RUN echo "#!/bin/bash" > /tmp/install_pkgs/create_ftp.sh && \
    echo "while true" >> /tmp/install_pkgs/create_ftp.sh && \
    echo "do" >> /tmp/install_pkgs/create_ftp.sh && \
    echo "  echo 'HMSET group:FTP repo_user repo repo_addr localhost name FTP repo_passwd' \$REPO_FTP_PASSWD|redis-cli" >> /tmp/install_pkgs/create_ftp.sh && \
    echo "  break" >> /tmp/install_pkgs/create_ftp.sh && \
    echo "done" >> /tmp/install_pkgs/create_ftp.sh && \
    chmod +x /tmp/install_pkgs/create_ftp.sh

# Install RVM for ruby apps
RUN \curl -L https://get.rvm.io | bash -s stable
ENV PATH /usr/local/rvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN /bin/bash -l -c "rvm requirements"
RUN /bin/bash -l -c "rvm install ruby-1.9.3"
RUN /bin/bash -l -c "rvm install ruby-2.1.2"
RUN /bin/bash -l -c "rvm use system --default"
RUN /bin/bash -l -c "gem install bundler --no-ri --no-rdoc"
RUN echo "umask u=rwx,g=rwx,o=rx" > /etc/rvmrc && \
    echo "rvm_gemset_create_on_use_flag=1" >> /etc/rvmrc

# Put your apps's depends below, all deps for your app needs to be installed in bricklayer container # 
#RUN apt-get -y install your_apps_depends 

EXPOSE 21 22 80 6379

CMD ["/usr/bin/supervisord"]
