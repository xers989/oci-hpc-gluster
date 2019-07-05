gluster volume set $1 performance.cache-samba-metadata on
gluster volume set $1 storage.batch-fsync-delay-usec 0
gluster volume set $1 group metadata-cache
gluster volume set $1 cluster.lookup-optimize off
