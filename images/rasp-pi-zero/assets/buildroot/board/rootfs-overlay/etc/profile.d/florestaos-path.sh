# /data/bin outranks the baked-in binaries — see `florestaos help`
# (update-florestad installs there so florestad iterations skip the
# image rebuild).  Interactive shells get the same view the init
# scripts use.
export PATH="/data/bin:$PATH"
