# brenmere-demo-build

Build shim for the hosted Brenmere demo on Render. Contains only a Dockerfile:
no application code, data or secrets. The source is fetched at build time
from a private repository using a read-only deploy key supplied by Render as
a build secret.
