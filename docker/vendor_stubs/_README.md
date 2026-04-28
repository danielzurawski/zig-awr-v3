# Vendor Python stubs (acceptance tests only)

These stubs replace the *hardware-touching* Python modules that the
vendor `Adeept_AWR-V3/Server/WebServer.py` imports. They are placed
*ahead* of the vendor Server directory on PYTHONPATH so that when
`WebServer.py` says `import Move` it gets our no-op stub instead of
the real Adafruit/CircuitPython-backed module that needs an I²C bus.

The point of the stubs is to let the **real vendor protocol code in
`WebServer.py`** boot inside a Docker container with no Pi hardware,
so we can exercise the actual auth handshake, `recv_msg` dispatcher,
and JSON response shapes against `ws-protocol-test.mjs`.

Two layers:

* **Module stubs (Move, Info, RPIservo, Functions, RobotLight, Switch,
  Voltage, app, camera_opencv)** — fake the local vendor modules.
* **Library stubs (board, busio, adafruit_pca9685, adafruit_motor)** —
  fake the Adafruit CircuitPython libraries the vendor pulls in via
  `from board import SCL, SDA` etc. We need these in case some vendor
  module is missed by the local-module stubs.

If a future vendor change adds a new module, the only change required
here is to add another stub file.
