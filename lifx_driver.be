import strict
import webserver
import string
import uuid
import json
import persist

class LifxDriver
  static var TRIGGERS = [
    # a set of plausible triggers for light power toggling
    [ "Button1#Action=SINGLE", "Button1#State=10" ],
    # a set of plausible triggers to force full brightness
    [ "Button1#Action=DOUBLE", "Button1#State=11" ]
  ]

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
  # a counter that increments every 250ms, used to allow period polling at multiples of the 250ms callback
  var tick

  def init()
    # XXX disable the next two lines in prod
    webserver.on('/lifx', / -> self.show_lifx_config(), webserver.HTTP_GET)
    webserver.on('/lifx', / -> self.set_lifx_config(), webserver.HTTP_POST)

    self.u = udp()
    self.u.begin("", 0)
    self.source = uuid.uuid4()[0..7] 
    self.discovery = {} 
    self.toggled = false # initial state, will get updated by polling bulbs
    self.powers = {}
    self.tick = 0 

    # This starts the LIFX integration if a configuration was previously saved
    self.assign_triggers();
  end
  # Web UI handling
  def web_add_handler()
    webserver.on('/lifx', / -> self.show_lifx_config(), webserver.HTTP_GET)
    webserver.on('/lifx', / -> self.set_lifx_config(), webserver.HTTP_POST)
  end
  def web_add_config_button()
    webserver.content_send('<p></p><form id="lifx" action="lifx" style="display: block;" method="get"><button name=""><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" style="fill: white;overflow: visible;" viewBox="0 -62 512 450"><path d="M353 346c-54-52-138-52-192 0q0 1 0 0-12-10-20-19A156 156 0 0 1 260 68q36 0 69 17c89 47 110 165 44 241q-6 8-19 20h-1Zm-173-55c54-27 117-24 168 8a1 1-54 0 0 1 0c49-60 29-151-41-184-47-22-104-11-139 27-40 45-41 110-5 157h1l15-8Z"></path><path d="M306 394a70 70 0 0 0-88-8l-10 8h-1l-21-21a1 1 0 0 1 0-1c41-39 102-39 142 0v1l-21 21a1 1 0 0 1-1 0Zm-24 25-25 24a1 1 0 0 1-1 1l-24-25v-1c14-13 36-14 50 0v1Z"></path></svg>Configure LIFX</button></form>')
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
    return s + '<option value="custom"'+(custom?' selected':'')+'>Custom Trigger Below:</select><p id="c'+str(idx)+'" style="display:none"><input name="cc'+str(idx)+'" placeholder="Device#State" value="'+webserver.html_escape(value)+'"></p>'
  end
  def show_lifx_config()
    if webserver.has_arg("j") # used by config page to refresh set of lights found
      self.lifx_discovery()
      return webserver.content_response(json.dump(self.discovery))
    end
    # restart discovery on config page load. this allows users to refresh the page to catch flaky wifi nodes.
    self.lifx_discovery()
    # emit HTML
    webserver.content_start("LIFX Configuration Page")
    webserver.content_send_style()
    webserver.content_send('<fieldset><legend><b> LIFX Configuration </b></legend><p style="width:320px;"><div>See the <a href="https://github.com/itsnotlupus/tasmota-switch-lifx/wiki" target="_blank">documentation</a>.</div><p><b>Choose the lights to control</b></p><form id="f" method="post"><table style="width:100%"><tbody id=t></tbody></table><p></p><hr><p><b>Trigger to toggle the lights</b><br>'+self.make_select(1,persist.lifx_trigger_toggle)+'</p><p><b>Trigger for full brightness</b><br>'+self.make_select(2,persist.lifx_trigger_brightness)+'</p><input type="hidden" name="group"><p></p><button class="button bgrn" name="setgrp" value="'+self.source+'">Save</button></form></fieldset>'
      # The following line is modified by ./build.sh using the content of the file config.js
      + '<script id="q">((c=5,wt=125,g='+json.dump(persist.lifx_group)+'??[],i='+json.dump(self.discovery)+',$=i=>document.querySelector(i),$$=i=>[...document.querySelectorAll(i)],e=s=>s.replace(/[&<>\'"]/g,c=>`&#x${c.charCodeAt().toString(16)};`),s=(t,c)=>$(t).onchange=()=>$(c).style.display=$(t).value=="custom"?"":"none",l=j=>{Object.entries(j).forEach(([id,[ip,label]])=>$("#"+id)?$(`label[for="${id}"]`).textContent=label:$`#t`.append(Object.assign(document.createElement`tr`,{innerHTML:`<td><input id="${e(id)}" name="${e(id)}" ${g.includes(id) ? "checked" : ""} type="checkbox"></td><td><label for="${e(id)}">${e(label)}</label></td><td>${e(ip)}</label></td>`})));$$`tbody label`.sort((l1,l2)=>l1.textContent.localeCompare(l2.textContent)).forEach(l=>$`#t`.append(l.parentElement.parentElement))},f=_=>setTimeout(async _=>{if(!c--)return;f();l(await(await fetch("?j=1")).json())},wt*=2))=>{$`#f`.onsubmit=_=>$`#f`.group.value=$$`tbody [type="checkbox"]`.filter(i=>i.checked).map(i=>i.name).join();s("#t1","#c1");s("#t2","#c2");l(i);f()})()</script>')
    webserver.content_button(webserver.BUTTON_CONFIGURATION)
    webserver.content_stop()
  end
  def set_lifx_config()
    var tiny_csrf_check = webserver.arg("setgrp");
    if tiny_csrf_check != self.source
      print("LifxDriver: Invalid POST /lifx request")
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
    # reset toggled data to not carry lingering info from devices that may have left the group
    self.toggled = false
    self.powers = {}
    webserver.content_start("LIFX Configuration Page")
    webserver.content_send_style()
    webserver.content_send('<div>Light Group Assigned.</div><div></div><div>Returning to LIFX Configuration page..</div><script>setTimeout(()=>location.replace("/lifx?"), 3000)</script>')
    webserver.content_stop()
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
    # we don't update self.toggled here. instead we wait for the next polling to confirm the change, update self.powers and therefore self.toggled
  end
  def trigger_full_brightness()
    self.group_action(/ ip, id -> self.lifx_set_brightness(ip, id, 0xffff))
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
      tasmota.cmd("LedPower "+(value?"On":"Off"), true) # XXX This behavior should be configurable
    end
  end
  def query_light_bulbs()
    var tried = false
    for id: persist.lifx_group
      if self.discovery.contains(id)
        var ip = self.discovery[id][0]
        self.lifx_query_power(ip, id)
      else
        if !tried
          # we're missing information about one or more light in our group. trigger a discovery to fix it.
          # this is the "normal" flow for lifx discovery to happen when the driver starts
          self.lifx_discovery()
          tried = true
        end
      end
    end
  end
  def every_second()
    self.tick +=1
    if !tasmota.eth()['up'] && !tasmota.wifi()['up']
      return # not connected to an IP network yet.
    end
    # 1. react to UDP payloads
    var packet = self.u.read()
    while packet != nil
      # minimal packet validation
      if packet.size() < 36
        print("LifxDriver: Unexpected UDP packet received", packet.tostring())
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
  def lifx_set_brightness(ip, id, brightness)
    # XXX This doesn't force the power on, which I think goes against the spirit of the double tap.
    var packet = bytes("3d000014")+bytes(self.source)+bytes(id)+bytes("00000000000000000202000000000000000077000000000000000000ffff0000000000000000803f00800000000100")
    # packet.set(84, brightness, 2) # brightness ranges 0 to 65535. I could pass floats around and convert but.. why.
    self.u.send(ip, 56700, packet)
  end
end

var lifx = LifxDriver()
tasmota.add_driver(lifx)
