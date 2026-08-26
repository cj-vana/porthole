# Porthole GSR helper

Gaming mode uses an app-owned gpu-screen-recorder helper so a loss recovery
request can force the next IDR without restarting the PipeWire portal and GPU
encoder. The patch targets upstream commit
`2552e7482315b50ec8bfeeb6a6cde1a60e6ff018` (GSR 6.0.1 plus twelve commits).

Build upstream with `gpu-screen-recorder-force-keyframe.patch`, then install
the resulting executable at:

```
/usr/local/libexec/porthole/gpu-screen-recorder
```

The helper reserves `SIGRTMIN+7` for “force the next encoded frame to an
intra/key frame.” The agent detects the helper by this exact path. If it is
absent, stock GSR remains supported and loss recovery falls back to rebuilding
the encoder session.
