import strict
import webserver
import string
import uuid
import json
import persist

# LifxDriver is one attempt to answer the question
#   "Why is a smart switch on a smart light such a dumb experience?"
#
# It is however an answer limited to smart switches running Tasmota and smart lights of the LIFX variety.
#

class LifxDriver
  static var TRIGGERS = [
    # a set of plausible triggers for light power toggling
    [ "Button1#Action=SINGLE", "Button1#State=10", "Switch1#state=2" ],
    # a set of plausible triggers to force full brightness
    [ "Button1#Action=DOUBLE", "Button1#State=11", "Switch1#state=3" ]
  ]

  # a flag to wait for things to be ready at startup
  var ready
  # a UDP socket to talk to LIFX devices
  var u
  # a random number that identifies us to the devices for this session
  var source
  # a map of {id=>[ip,label,seen]} used to send direct commands to devices, and to show user-friendly names in the config page
  var discovery
  # a boolean, our best understanding of whether any of the lights in our group is turned on right now
  var toggled
  # a map of {id => bool} used to track what devices tell us about being turned on
  var powers
  # a boolean, true if we lost network and our config tells us becoming dumb is better than becoming broken.
  var failsafe_mode
  # a counter that increments every 250ms, used to allow period polling at multiples of the 250ms callback
  var tick

  def init()
    self.ready = false
    self.source = uuid.uuid4()[0..7] 
    self.discovery = {} 
    self.toggled = false # initial state, will get updated by polling bulbs
    self.powers = {}
    self.failsafe_mode = false
    self.tick = 0 
    # wait for every_second() to call startup() once network is up.
  end
  def startup()
    if tasmota.millis() > 20000
      # if this is ran manually after startup, web_add_handler() won't get called for us.
      self.web_add_handler()
    end

    # setup relevant commands
    self.setup_options()

    # start networking
    self.u = udp()
    self.u.begin("", 0)

    # This starts the LIFX integration if a configuration was previously saved
    self.assign_triggers()

    self.log("Initialized")
  end
  def log(*args)
    call(print, "Lifx:", args)
  end
  # Web UI handling
  def web_add_handler()
    webserver.on('/lifx', / -> self.show_lifx_config(), webserver.HTTP_GET)
    webserver.on('/lifx', / -> self.set_lifx_config(), webserver.HTTP_POST)
  end
  def web_add_config_button()
    webserver.content_send('<p></p><form id="lifx" action="lifx" style="display: block;" method="get"><button name=""><svg xmlns="http://www.w3.org/2000/svg" width="24" fill="white" viewBox="0 0 24 24" style="vertical-align: text-bottom;"><path d="M10.04.06a9.98 9.78 0 0 0-7.1 2.89 10.1 9.9 0 0 0-2.94 7 10.1 9.88 0 0 0 2.94 7l.87.83.04-.04a8.76 8.58 0 0 1 6.2-2.5 8.8 8.6 0 0 1 6.2 2.5l.05.04.85-.85a10.13 9.92 0 0 0 2.94-7c0-2.53-.98-5.06-2.94-6.99a10.08 9.87 0 0 0-7.1-2.88zm0 2.28a7.67 7.51 0 0 1 5.46 2.22 7.8 7.64 0 0 1 .5 10.22 10.98 10.75 0 0 0-11.94 0 7.86 7.7 0 0 1-1.75-4.83c0-1.94.76-3.9 2.27-5.4a7.64 7.48 0 0 1 5.46-2.21zm0 15.16a6.6 6.6 0 0 0-4.62 1.89l1.43 1.4a4.53 4.43 0 0 1 6.4 0l1.43-1.4a6.62 6.62 0 0 0-4.64-1.89zm0 4.16a2.27 2.22 0 0 0-1.63.67l1.63 1.61 1.63-1.6a2.25 2.2 0 0 0-1.63-.68z"></path></svg> Configure LIFX</button></form>')
  end
  def make_select(idx, value)
    var presets = self.TRIGGERS[idx-1]
    var s = '<select id="t'+str(idx)+'" name="t'+str(idx)+'"><option value=""'+(value?'':' selected')+'>--No Trigger--</option>'
    var found = false
    for trigger: presets
      var attr=''
      if trigger == value
        found = true
        attr = " selected"
      end
      s += '<option'+attr+'>'+trigger
    end
    var custom = value && !found
    return s + '<option value="custom"'+(custom?' selected':'')+'>Custom Trigger Below:</select><p id="c'+str(idx)+'" style="display:'+(custom?'':'none')+'"><input name="cc'+str(idx)+'" placeholder="Device#State" value="'+(value==nil?'':webserver.html_escape(value))+'"></p>'
  end
  def show_lifx_config()
    if webserver.has_arg("j") # used by config page to refresh set of lights found
      self.lifx_discovery()
      return webserver.content_response(json.dump(self.discovery))
    end
    def test_lights(action)
      if webserver.arg("src") != self.source return end
      for id: string.split(webserver.arg("ids"), ",")
        if self.discovery.contains(id)
          var ip = self.discovery[id][0]
          action(ip, id)
        end
      end
      webserver.content_response('{}')
    end
    if webserver.has_arg("tl") # test for light toggles
      return test_lights(/ ip,id -> self.lifx_toggle_power(ip, id, false))
    end
    if webserver.has_arg("fb") # test for full brightness
      return test_lights(def (ip,id)
        self.lifx_set_brightness(ip, id, 0xffff)
        self.lifx_toggle_power(ip, id, true)
      end)
    end
    var led_checked = / -> persist.lifx_led != false ? " checked":""
    var relay_checked = / -> persist.lifx_relay != false ? " checked": ""
    var failsafe_checked = / -> persist.lifx_failsafe != false ? " checked": ""
    # restart discovery on config page load. this allows users to refresh the page to catch flaky wifi nodes.
    self.lifx_discovery()
    # emit HTML
    webserver.content_start("LIFX Configuration Page")
    webserver.content_send_style()
    webserver.content_send('<fieldset><legend><b> LIFX Configuration </b></legend><p style="width:320px;"><div>See the <a href="https://github.com/itsnotlupus/tasmota-switch-lifx/wiki" target="_blank">documentation</a>.</div><p><b>Choose the lights to control</b></p><form id="f" method="post"><table style="width:100%"><tbody id=t></tbody></table><p></p><hr><p><b>Test your selection</b><div style="display:flex;gap:1em"><button id="tl" type="button">Lights Off</button><button id="fb" type="button">Full Brigthness</button></div><p></p><hr><p><b>Trigger to toggle the lights</b></p><p>'+self.make_select(1,persist.lifx_trigger_toggle)+'</p><p><b>Trigger for full brightness</b></p><p>'+self.make_select(2,persist.lifx_trigger_brightness)+'</p><p></p><hr><p><b>Options</b><div><label><input type="checkbox" name="o1"'+led_checked()+'>Associate LED state to the lights</label></div><div><label><input type="checkbox" name="o2" id="o2"'+relay_checked()+'>Detach relay</label></div><div><label><input type="checkbox" name="o3" id="o3"'+failsafe_checked()+'>Attach relay while network is down</label></div></p><input type="hidden" name="group"><p></p><button class="button bgrn" name="setgrp" value="'+self.source+'">Save</button></form></fieldset>'
      # The following line is modified by ./build.sh using the content of the file config.js
      + '<script id="q">((c=5,wt=125,g='+json.dump(persist.lifx_group)+'??[],i='+json.dump(self.discovery)+',$=i=>document.querySelector(i),$$=i=>[...document.querySelectorAll(i)],e=s=>s.replace(/[&<>\'"]/g,c=>`&#x${c.charCodeAt().toString(16)};`),s=(t,c)=>$(t).onchange=()=>$(c).style.display=$(t).value=="custom"?"":"none",w=_=>$$`tbody [type="checkbox"]`.filter(i=>i.checked).map(i=>i.name).join(),b=i=>$("#"+i).onclick=_=>fetch(`?${i}=1&ids=${w()}&src=${$`[name="setgrp"]`.value}`),l=j=>{Object.entries(j).forEach(([id,[ip,label]])=>$("#"+id)?$(`label[for="${id}"]`).textContent=label:$`#t`.append(Object.assign(document.createElement`tr`,{innerHTML:`<td><input id="${e(id)}" name="${e(id)}" ${g.includes(id)?"checked":""} type="checkbox"></td><td><label for="${e(id)}">${e(label)}</label></td><td>${e(ip)}</label></td>`})));$$`tbody label`.sort((l1,l2)=>l1.textContent.localeCompare(l2.textContent)).forEach(l=>$`#t`.append(l.parentElement.parentElement))},f=_=>setTimeout(async _=>{if(!c--)return;f();l(await(await fetch("?j=1")).json())},wt*=2))=>{$`#f`.onsubmit=_=>$`#f`.group.value=w();s("#t1","#c1");s("#t2","#c2");b("tl");b("fb");$("#o2").onchange=(e,w=$("#o3"))=>(w.disabled=!$("#o2").checked)&&(w.checked=false);l(i);f()})();</script>')
    webserver.content_button(webserver.BUTTON_CONFIGURATION)
    webserver.content_stop()
  end
  def set_lifx_config()
    var tiny_csrf_check = webserver.arg("setgrp")
    if tiny_csrf_check != self.source
      self.log("Invalid POST /lifx request")
      return
    end
    persist.lifx_group = string.split(webserver.arg("group"),',')
    # We will gleefully accept any trigger here. caveat haxor.
    var trigger_for_toggle = webserver.arg("t1")
    if trigger_for_toggle == "custom"
      trigger_for_toggle = webserver.arg("cc1")
    end
    var trigger_for_brightness = webserver.arg("t2")
    if trigger_for_brightness == "custom"
      trigger_for_brightness = webserver.arg("cc2")
    end
    self.assign_triggers(trigger_for_toggle, trigger_for_brightness)
    # Assign options
    persist.lifx_led = webserver.arg("o1") == "on"
    persist.lifx_relay = webserver.arg("o2") == "on"
    persist.lifx_failsafe = webserver.arg("o3") == "on"
    self.setup_options()
    # reset toggled data to not carry lingering info from devices that may have left the group
    self.toggled = false
    self.powers = {}
    webserver.content_start("LIFX Configuration Page")
    webserver.content_send_style()
    webserver.content_send('<div>Settings applied.</div><div></div><div>Returning to LIFX Configuration page..</div><script>setTimeout(()=>location.replace("/lifx?"), 3000)</script>')
    webserver.content_stop()
  end
  def setup_options()
    # mess with SetOption commands to line up the behaviors we want.
    if !persist.lifx_led
      tasmota.cmd("LedState 1")
    end
    # this if/elif seems gauche, but it allows the `nil` case to fall through,
    # which avoids running commands until the user saves a configuration.
    if persist.lifx_relay == true
      self.detach_relay()
    elif persist.lifx_relay == false 
      self.attach_relay()
    end
  end
  # Trigger handling
  def assign_triggers(trigger_toggle, trigger_brightness)
    # don't pile on rules
    tasmota.remove_rule(persist.lifx_trigger_toggle, "lifx_toggle")
    tasmota.remove_rule(persist.lifx_trigger_brightness, "lifx_brightness")
    # update triggers if given.
    if trigger_toggle != nil
      persist.lifx_trigger_toggle = trigger_toggle
    end
    if trigger_brightness != nil
      persist.lifx_trigger_brightness = trigger_brightness
    end
    # don't set rules with empty triggers, they act as full wildcards
    if persist.lifx_trigger_toggle
      tasmota.add_rule(persist.lifx_trigger_toggle, / -> self.trigger_toggle_lights(), "lifx_toggle")
    end
    if persist.lifx_trigger_brightness
      tasmota.add_rule(persist.lifx_trigger_brightness, / -> self.trigger_full_brightness(), "lifx_brightness")
    end
  end
  def group_action(action) 
    var tried = false
    for id: persist.lifx_group
      if self.discovery.contains(id)
        var ip = self.discovery[id][0]
        action(ip, id)
      else
        # we're missing an IP address to control one or more LIFX devices
        # it's too late for this interaction, but try to fix it for the next one
        if !tried
          self.lifx_discovery()
          tried = true
        end
      end
    end
  end
  def trigger_toggle_lights()
    self.group_action(/ ip, id -> self.lifx_toggle_power(ip, id, !self.toggled))
    # we don't update self.toggled here. instead we query the bulbs to confirm the change, update self.powers and therefore self.toggled
    self.query_light_bulbs()
  end
  def trigger_full_brightness()
    self.group_action(def (ip, id)
      # full brightness also turns the light on
      self.lifx_set_brightness(ip, id, 0xffff)
      self.lifx_toggle_power(ip, id, 0xffff)
    end)
  end
  def query_light_bulbs()
    self.group_action(/ ip, id -> self.lifx_query_power(ip, id))
  end
  def update_toggle(power)
    var value = power # shortcut. any light on means the whole group is considered on
    if !value
      # we have to loop to check if any light is still on
      for p: self.powers
        if p
          value = true
          break
        end
      end
    end
    if value != self.toggled
      self.toggled = value
      if persist.lifx_led
        tasmota.cmd("LedPower "+(value?"On":"Off"), true)
      end
    end
  end
  def every_second()
    self.tick +=1
    if !tasmota.eth()['up'] && !tasmota.wifi()['up']
      # If we are in a running state and lose network, we can become an ordinary switch (failsafe mode)
      if self.ready && persist.lifx_failsafe && !self.failsafe_mode
        self.attach_relay()
        self.failsafe_mode = true
      end
      return # don't touch the network APIs when not connected to an IP network.
    end
    if !self.ready
      self.ready = true
      self.startup()
    end
    # If we were in failsafe mode and the network is back, detach the relay again and act smart.
    if self.failsafe_mode
      self.detach_relay()
      self.failsafe_mode = false
    end
    # 1. react to UDP payloads
    var packet = self.u.read()
    while packet != nil
      # minimal packet validation
      if packet.size() < 36
        self.log("Unexpected UDP packet received", packet.tostring())
        continue
      end
      var cmd=packet.get(32,2)
      var id = packet[8..13].tohex()
      if cmd == 3 # StateService
        var tmp_label = self.discovery.contains(id) ? self.discovery[id][1] : "LIFX Device"
        self.discovery[id] = [self.u.remote_ip, tmp_label, self.tick]
        # Ask for a human-friendly label to show the user
        self.lifx_query_label(self.u.remote_ip, id)
      elif cmd == 25 # StateLabel 
        var label = string.split(packet[36..68].asstring(),"\000", 0)[0] # truncate string at its first null..
        self.discovery[id] = [self.u.remote_ip, label, self.tick]
      elif cmd == 22 # StatePower
        var power = packet.get(36,2) != 0
        self.powers[id] = power
        self.update_toggle(power)
      end
      packet = self.u.read()
    end
    # 2. periodically poll lights in our group for their state
    # this needs to be short enough for the backlight led to update when the button is pushed
    if self.tick%2 == 0 # 2 seconds
      self.query_light_bulbs()
    end
    # 3. periodically refresh our mapping of lifx ids to IP# and labels
    if self.tick%120 == 0 # 2 minutes
      # forget about devices that haven't been seen in 5 minutes
      # NOTE: if they are in the group, this will cause a discovery every 2 seconds until they come back on
      for id: self.discovery.keys()
         if self.tick-self.discovery[id][2] > 300
          self.discovery.remove(id)
        end
      end
      self.lifx_discovery()
    end
  end
  # Relay control
  # NOTE: These commands may not be appropriate for all devices. 
  def attach_relay()
    self.log("Attaching relay")
    tasmota.cmd("SetOption73 0", true) # attach button from relay
    tasmota.cmd("SetOption114 0", true) # attach switch from relay
    if persist.lifx_led
      tasmota.cmd("LedState 1")
    end
  end
  def detach_relay()
    self.log("Detaching relay")
    tasmota.cmd("SetOption73 1", true) # detach button from relay
    tasmota.cmd("SetOption114 1", true) # detach switch from relay
    if persist.lifx_led
      tasmota.cmd("LedPower "+(self.toggled?"On":"Off"), true)
    end
  end
  # half baked ipv4 address to/from string conversion.
  def inet_aton(a)
    var c = string.split(a,".")
    return int(c[0])*0x1000000+int(c[1])*0x10000+int(c[2])*0x100+int(c[3])
  end
  def inet_ntoa(n)
    return string.format("%s.%s.%s.%s", (n>>24)&255,(n>>16)&255,(n>>8)&255,n&255)
  end
  def get_broadcast_address()
    var net = tasmota.cmd('Status 5', true)['StatusNET']
    return self.inet_ntoa(~self.inet_aton(net['Subnetmask'])|self.inet_aton(net["IPAddress"]))
  end
  # miminal LIFX LAN chatter - grossly hardcoded UDP packets to interact with LIFX devices.
  def lifx_discovery()
    # Broadcast an LIFX GetService message. This should make all lifx devices send a StateService reply.
    self.u.send(self.get_broadcast_address(), 56700, bytes("24000034")+bytes(self.source)+bytes("00000000000000000000000000000101000000000000000002000000"))
  end
  def lifx_query_label(ip, id)
    self.u.send(ip, 56700, bytes("24000014")+bytes(self.source)+bytes(id)+bytes("00000000000000000301000000000000000017000000"))
  end
  def lifx_query_power(ip, id) 
    self.u.send(ip, 56700, bytes("24000014")+bytes(self.source)+bytes(id)+bytes("00000000000000000301000000000000000014000000"))
  end
  def lifx_toggle_power(ip, id, on)
    self.u.send(ip, 56700, bytes("26000014")+bytes(self.source)+bytes(id)+bytes("00000000000000000201000000000000000015000000")+bytes(on ? "ffff" : "0000"))
  end
  def lifx_query_color(ip, id)
    self.u.send(ip, 56700, bytes("24000014")+bytes(self.source)+bytes(id)+bytes("00000000000000000101000000000000000065000000"))
  end
  # brightness is a uint16. 0x0000 = no brightness, 0xffff = full brightness, and anything in between.
  def lifx_set_brightness(ip, id, brightness)
    var packet = bytes("3d000014")+bytes(self.source)+bytes(id)+bytes("00000000000000000202000000000000000077000000000000000000ffff0000000000000000803f00800000000100")
    packet.set(42, brightness, 2)
    self.u.send(ip, 56700, packet)
  end
end

var lifx = LifxDriver()
tasmota.add_driver(lifx)
