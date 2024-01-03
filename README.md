# RSMP 4 Client
This is part of an experiment to see how RSMP 4 could be build on top of MQTT.

This Phoenix web app acts as an RSMP client.

## Running
The MQTT broker and the MQTT device (rsmp_mqtt) should be running (or you can start them afterwards)-

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:3000`](http://localhost:3000) from your browser.


## CLI
From iex (Interactive Elixir) you can use the RSMP.Client module to interact with RSMP MQTT clients. If you have a supervisor, you should see the client appear online, send status messages, etc:

```sh
%> iex -S mix
Erlang/OTP 25 [erts-13.2.2.3] [source] [64-bit] [smp:8:8] [ds:8:8:10] [async-threads:1]

Interactive Elixir (1.15.5) - press Ctrl+C to exit (type h() ENTER for help)

iex(1)> {:ok,pid} = RSMP.Client.start_link()   # start our client, will send state, statuses and alarms
[info] RSMP: Starting client with pid #PID<0.342.0>
{:ok, #PID<0.342.0>}

iex(4)> pid |> RSMP.Client.get_id()  # show our RSMP/MQTT id
"tlc_b2926093"

iex(5)> pid |> RSMP.Client.get_statuses()  # show our local statuses
%{
  "main/system/humidity" => 48,
  "main/system/plan" => 1,
  "main/system/temperature" => 28
}

iex(6)> pid |> RSMP.Client.get_alarms()  # show our local alarms
%{
  "main/system/humidity" => %{
    "acknowledged" => false,
    "active" => false,
    "blocked" => false
  },
  "main/system/temperature" => %{
    "acknowledged" => false,
    "active" => false,
    "blocked" => false
  }
}

iex(7)> pid |> RSMP.Client.set_status("main/system/humidity",49)  # will publish our status, if changed
:ok

iex(9)> pid |> RSMP.Client.raise_alarm("main/system/temperature") # will publish alarm, if chahnged
:ok

iex(11)> pid |> RSMP.Client.clear_alarm("main/system/temperature") # will publish alarm, if changed
:ok
```
