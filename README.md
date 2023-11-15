# Rsmp
This is part of an experiment to see how RSMP 4 could be build on top of MQTT.


This Phoenix web app receives data from an MQTT device (rsmp_mqtt) and graphs it.
You can also send a command to the device.


## Running
The MQTT broker and the MQTT device (rsmp_mqtt) should be running (or you can start them afterwards)-

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.
