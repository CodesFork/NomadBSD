ARCH=		amd64
RELEASE=	11.1-RELEASE
URL=		ftp://ftp.freebsd.org/pub/FreeBSD/releases
# Media size in GB
MEDIASIZE=	4
# Size of swap partition in MB
SWAPSIZE=	128
FRAGSIZE=	2048
SYSDIR=		${PWD}/sys
DISTDIR=	${PWD}/dists
DISTSITE=	${URL}/${ARCH}/${RELEASE}
DISTS=		base.txz
PKGLIST=	pkg.list
GIT_SITE=	https://github.com/mrclksr
GIT_REPOS=	${GIT_SITE}/DSBDriverd.git
GIT_REPOS+=	${GIT_SITE}/DSBMC.git
GIT_REPOS+=	${GIT_SITE}/DSBMC-Cli.git
GIT_REPOS+=	${GIT_SITE}/DSBMD.git
GIT_REPOS+=	${GIT_SITE}/dsbcfg.git
GIT_REPOS+=	${GIT_SITE}/libdsbmc.git
GIT_REPO_DIRS=	DSBDriverd DSBMC DSBMC-Cli DSBMD

KERNELTARGET=	${SYSDIR}/usr/obj/usr/src/sys/NOMADBSD/kernel
PKGDB=		${SYSDIR}/var/db/pkg/local.sqlite
XORG_CONF_D=	${SYSDIR}/usr/local/etc/X11/xorg.conf.d
FONTSDIR=	${SYSDIR}/usr/local/share/fonts
FONTPATHS_FILE=	${XORG_CONF_D}/files.conf
UZIP_IMAGE=	uzip_image
UZIP_MNT=	uzip_mnt

.ifdef BUILDKERNEL
DISTS+=	src.txz
.endif

init: initbase buildkernel instpkgs fontpaths
	(cd nomad  && tar cf - .) | (cd ${SYSDIR}/usr/home/nomad && tar xf -)
	chroot ${SYSDIR} sh -c 'chown -R nomad:nomad /usr/home/nomad'
.ifdef BUILDKERNEL
	(cd kernel && tar cf - .) | \
	    (cd ${SYSDIR}/usr/src/sys/${ARCH}/conf && tar xf -)
.endif

initbase: ${SYSDIR}
	if ! grep -q ^nomad ${SYSDIR}/etc/passwd; then \
		chroot ${SYSDIR} sh -c \
		    'pw useradd nomad -m -G wheel,operator,video \
		    -s /bin/csh'; \
	fi
	(cd config && tar cf - .) | \
	    (cd ${SYSDIR} && tar -xf - --uname root --gname wheel)
	chroot ${SYSDIR} sh -c 'cap_mkdb /etc/login.conf'

fontpaths: ${FONTPATHS_FILE}

${FONTPATHS_FILE}: instpkgs
	if [ ! -d ${XORG_CONF_D} ]; then mkdir -p ${XORG_CONF_D}; fi
	(for i in ${FONTSDIR}/*; do \
		mkfontscale "$$i/"; \
		mkfontdir "$$i/"; \
	done; \
	echo "Section \"Files\""; \
	IFS=; \
	for i in ${FONTSDIR}/*; do \
		n=`head -1 "$$i/fonts.scale"`; \
		i=`echo $$i | sed -E 's#${SYSDIR}(/.*)$$#\1#'`; \
		if [ $$n -gt 0 ]; then \
			echo "  FontPath \"$$i\""; \
		else \
			if [ ! -z $${ns} ]; then \
				ns=`printf "$${ns}\n$$i"`; \
			else \
				ns="$$i"; \
			fi \
		fi \
	done; \
	echo $${ns} | while read i; do \
		echo "  FontPath \"$$i\""; \
	done; \
	echo "EndSection") > ${FONTPATHS_FILE}

${SYSDIR}:
	BSDINSTALL_DISTDIR=${DISTDIR} BSDINSTALL_DISTSITE=${DISTSITE} \
	    DISTRIBUTIONS="${DISTS}" bsdinstall jail ${SYSDIR}
	BSDINSTALL_DISTDIR=${DISTDIR} DISTRIBUTIONS=kernel.txz \
	BSDINSTALL_DISTSITE=${DISTSITE} bsdinstall distfetch
	BSDINSTALL_DISTDIR=${DISTDIR} BSDINSTALL_CHROOT=${SYSDIR} \
	    DISTRIBUTIONS=kernel.txz bsdinstall distextract

instpkgs: ${PKGDB}
	if grep -q ^cups: ${SYSDIR}/etc/group; then \
		chroot ${SYSDIR} sh -c 'pw groupmod cups -m root,nomad'; \
	fi

${PKGDB}: initbase ${PKGLIST}
	export ASSUME_ALWAYS_YES=yes; \
	    cat ${PKGLIST} | xargs -J% pkg -c ${SYSDIR} install -y %
	if [ ! -d ${SYSDIR}/git ]; then mkdir ${SYSDIR}/git; fi
.for r in ${GIT_REPOS}
	if [ ! -d ${SYSDIR}/git/${r:S,${GIT_SITE}/,,:S,.git,,} ]; then \
		chroot ${SYSDIR} sh -c 'cd /git && git clone ${r}'; \
	fi
.endfor
.for r in ${GIT_REPO_DIRS}
	chroot ${SYSDIR} sh -c 'cd /git/${r} && make && make install'
.endfor
	cp ${SYSDIR}/usr/local/etc/dsbmd.conf.sample \
	    ${SYSDIR}/usr/local/etc/dsbmd.conf
buildkernel: ${KERNELTARGET}

${KERNELTARGET}: initbase
.ifdef BUILDKERNEL
	if [ ! -f ${SYSDIR}/usr/src/Makefile ]; then \
		BSDINSTALL_DISTDIR=${DISTDIR} DISTRIBUTIONS=src.txz \
		    BSDINSTALL_DISTSITE=${DISTSITE} bsdinstall distfetch; \
		BSDINSTALL_DISTDIR=${DISTDIR} BSDINSTALL_CHROOT=${SYSDIR} \
		    DISTRIBUTIONS=src.txz bsdinstall distextract; \
	fi
	if [ ! -f ${SYSDIR}/usr/obj/usr/src/sys/NOMADBSD/kernel ]; then \
		(cd kernel && tar cf - .) | \
		    (cd ${SYSDIR}/usr/src/sys/${ARCH}/conf && tar xf -); \
		chroot ${SYSDIR} sh -c \
		    'mount -t devfs devfs /dev; \
		    cd /usr/src && make KERNCONF=NOMADBSD kernel'; \
		umount ${SYSDIR}/dev; \
	fi
.endif

image: nomadbsd.img

nomadbsd.img: uzip
	touch nomadbsd.img; \
	blksize=`echo "${FRAGSIZE} * 8" | bc`; \
	maxsize=`echo "scale=0; ${MEDIASIZE} * 1000^3 / 1024 - \
	    5 * (${MEDIASIZE} * 1000^3 / 1024) / 100" | bc`; \
	mddev=`mdconfig -a -t vnode -f $@ -s $${maxsize}k || exit 1`; \
	fdisk -BI /dev/$${mddev} || exit 1; \
	bsdlabel -w -B -b ${SYSDIR}/boot/boot /dev/$${mddev}s1 || exit 1; \
	bsdlabel /dev/$${mddev}s1 | sed -e '/^ *a:/d' > disklabel; \
	echo "  a: *    16 unused 0 0" >> disklabel; \
	echo "  b: ${SWAPSIZE}M  * swap   0 0" >> disklabel; \
	bsdlabel -R /dev/$${mddev}s1 disklabel; \
	rm -f disklabel; \
	glabel label NomadBSDsw /dev/$${mddev}s1b || exit 1; \
	newfs -E -U -O 1 -L NomadBSD -b $${blksize} -f ${FRAGSIZE} \
	    -m 0 /dev/$${mddev}s1a || exit 1; \
	if [ ! -d mnt ]; then mkdir mnt || exit 1; sleep 1; fi; \
	mount /dev/$${mddev}s1a mnt || exit 1; \
	(cd ${SYSDIR} && rm -rf var/tmp/*; rm -rf tmp/*); \
	(cd ${SYSDIR} && tar -cf - \
	    --exclude '^boot/kernel.old' \
	    --exclude '^git*'		 \
	    --exclude '^pkgs/*'		 \
	    --exclude '^usr/obj*'	 \
	    --exclude '^usr/src*'	 \
	    --exclude '^usr/ports*'	 \
	    --exclude '^usr/*/doc/*'	 \
	    --exclude '^usr/local'	 \
	    --exclude '^home*'		 \
	    --exclude '^usr/home*'	 \
	    --exclude '^var/cache/pkg*'	 \
	    --exclude '^var/db/portsnap/*' \
	    --exclude '^var/db/ports/*'	 \
	    --exclude '^var/log/*' .) | (cd mnt && tar pxf -); \
	mkdir mnt/var/log; mkdir -p mnt/home/nomad; \
	(cd ${SYSDIR}/usr/home/nomad && tar cf - .) | \
	    (cd mnt/home/nomad && tar vpxf -); \
	mkdir mnt/usr.local.etc; \
	(cd ${SYSDIR}/usr/local/etc && tar cf - .) | \
 	    (cd mnt/usr.local.etc && tar vpxf -); \
	mkdir mnt/uzip; mkdir mnt/usr/local; \
	cp ${UZIP_IMAGE}.uzip mnt/uzip/usr.local.uzip; \
	umount mnt || umount -f mnt; mdconfig -d -u $${mddev}; \
	rmdir mnt

uzip: ${UZIP_IMAGE}.uzip

${UZIP_IMAGE}.img: init
	blksize=`echo "${FRAGSIZE} * 8" | bc`; \
	touch ${UZIP_IMAGE}.img; \
	mddev=`mdconfig -a -t vnode -f ${UZIP_IMAGE}.img -s 6000m || exit 1`; \
	newfs -O 1 -b $${blksize} -f ${FRAGSIZE} -m 0 /dev/$${mddev} || \
	    exit 1; \
	if [ ! -d ${UZIP_MNT} ]; then mkdir ${UZIP_MNT} || exit 1; fi; \
	mount /dev/$${mddev} ${UZIP_MNT} || exit 1; \
	(cd ${SYSDIR}/usr/local && tar -cf -	\
	    --exclude '^etc' .) | (cd ${UZIP_MNT} && tar pxf -); \
	(cd ${UZIP_MNT} && ln -s /usr.local.etc etc); \
	umount ${UZIP_MNT} || umount -f ${UZIP_MNT}; \
	mdconfig -d -u $${mddev}; \
	rmdir ${UZIP_MNT}

${UZIP_IMAGE}.uzip: ${UZIP_IMAGE}.img
	mkuzip -d -o ${UZIP_IMAGE}.uzip ${UZIP_IMAGE}.img

baseclean:
	chflags -R noschg,nosunlnk ${SYSDIR}
	rm -rf ${SYSDIR}

uzipclean:
	rm -f ${UZIP_IMAGE}.img ${UZIP_IMAGE}.uzip

kernelclean:
	chroot ${SYSDIR} sh -c \
	    'mount -t devfs devfs /dev;	\
	    cd /usr/src && make KERNCONF=NOMADBSD cleankernel'
	umount ${SYSDIR}/dev

distclean:
	rm -rf ${DISTDIR}/*

clean: distclean baseclean uzipclean

allclean: clean
	rm -f nomadbsd.img
