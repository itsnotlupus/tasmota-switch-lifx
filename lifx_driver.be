import strict
import webserver
import string
import uuid
import json
import persist

class LifxDriver
  var u
  var source
  var discovery
  var toggled

  def init()
    # disable the next two line in prod
    webserver.on('/lifx', / -> self.show_lifx_config(), webserver.HTTP_GET)
    webserver.on('/lifx', / -> self.set_lifx_config(), webserver.HTTP_POST)
    self.u = udp()
    self.u.begin("", 0)
    self.source = uuid.uuid4()[0..7] 
    self.discovery = {} # map of {id=>[ip,label]}
    self.toggled = false # XXX wrong. ideally, we'd populate that by querying the state of the lights in our group
    # emit a LIFX GetService broadcast early.
    self.start_discovery()
    # define rules. XXX should we configure/introspect to match device config?
    tasmota.add_rule("Button1#Action=SINGLE", / -> self.button_click())
  end
  def web_add_handler()
    webserver.on('/lifx', / -> self.show_lifx_config(), webserver.HTTP_GET)
    webserver.on('/lifx', / -> self.set_lifx_config(), webserver.HTTP_POST)
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
    var net = tasmota.cmd('Status 5')['StatusNET']
  return self.inet_ntoa(~self.inet_aton(net['Subnetmask'])|self.inet_aton(net["IPAddress"]))
  end
  def start_discovery()
    # Broadcast an LIFX GetService message
  self.u.send(self.get_broadcast_address(), 56700, bytes("24000034")+bytes(self.source)+bytes("00000000000000000000000000000101000000000000000002000000")); 
  end
  def web_add_config_button()
    webserver.content_send('<p></p><form id="lifx" action="lifx" style="display: block;" method="get"><button name=""><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" style="fill: white;overflow: visible;" viewBox="0 -62 512 450"><path d="M353 346c-54-52-138-52-192 0q0 1 0 0-12-10-20-19A156 156 0 0 1 260 68q36 0 69 17c89 47 110 165 44 241q-6 8-19 20h-1Zm-173-55c54-27 117-24 168 8a1 1-54 0 0 1 0c49-60 29-151-41-184-47-22-104-11-139 27-40 45-41 110-5 157h1l15-8Z"></path><path d="M306 394a70 70 0 0 0-88-8l-10 8h-1l-21-21a1 1 0 0 1 0-1c41-39 102-39 142 0v1l-21 21a1 1 0 0 1-1 0Zm-24 25-25 24a1 1 0 0 1-1 1l-24-25v-1c14-13 36-14 50 0v1Z"></path></svg>Configure LIFX</button></form>')
  end
  def show_lifx_config()
    if webserver.has_arg("j") 
      self.start_discovery() # A bit noisy, but who's watching
     return webserver.content_response(json.dump(self.discovery))
    end
    # restart discovery on config page load. this allows users to refresh the page to catch flaky wifi nodes.
    self.start_discovery()
    webserver.content_start("LIFX Configuration Page")
    webserver.content_send_style()
    webserver.content_send('<fieldset><legend><b> Select your LIFX lights </b></legend><p style="width:320px;"><form id="f" method="post"><table style="width:100%"><tbody id=t></tbody></table><div></div><hr><label><input type="checkbox" '+(persist.lifx_active?'checked':'')+' name="active">Use Button1 to control LIFX lights</label><input type="hidden" name="group"><div></div><button class="button bgrn" name="setgrp">Assign Light Group</button></form></fieldset>'
      + '<script>((c=5,wt=125,g='+json.dump(persist.lifx_group)+'??[],i='+json.dump(self.discovery)+',e=s=>s.replace(/[&<>\'"]/g,c=>`&#x${c.charCodeAt().toString(16)};`),l=j=>{Object.entries(j).filter(([id])=>!eb(id)).forEach(([id,[ip,label]])=>eb`t`.append(Object.assign(document.createElement`tr`,{innerHTML:`<td><input id="${e(id)}" name="${e(id)}" ${g.includes(id)?"checked":""} type="checkbox"></td><td><label for="${e(id)}">${e(label)}</label></td><td>${e(ip)}</label></td>`})));[...document.querySelectorAll`tbody label`].sort((l1,l2)=>l1.textContent.localeCompare(l2.textContent)).forEach(l=>eb`t`.append(l.parentElement.parentElement))},f=_=>setTimeout(async _=>{if(!c--)return;f();l(await(await fetch("?j=1")).json())},wt*=2))=>{eb`f`.onsubmit=_=>eb`f`.group.value=[...document.querySelectorAll`tbody input[type="checkbox"]`].filter(i=>i.checked).map(i=>i.name).join();l(i);f()})()</script>')
    webserver.content_button(webserver.BUTTON_CONFIGURATION)
    webserver.content_stop()
  end
  def set_lifx_config()
    if (!webserver.has_arg("setgrp"))
      return
    end
    var active = webserver.arg("active")
    var group = string.split(webserver.arg("group"),',')
    print("POST Config: active=",active," group=",group)
    persist.lifx_group = group
    persist.lifx_active = active == 'on'
    webserver.content_start("LIFX Configuration Page")
    webserver.content_send_style()
    webserver.content_send('<div>Light Group Assigned.</div><div></div><div>Returning to LIFX Configuration page..</div><script>setTimeout(()=>location.replace("/lifx?"), 3000)</script>')
    webserver.content_stop()
  end
  def button_click()
    if !persist.lifx_active 
      return
    end
    self.toggled = !self.toggled
    for id: persist.lifx_group
      try
        var ip = self.discovery[id][0]
        self.toggle_light_bulb(ip, id, self.toggled)
      except
        print("LIFXDriver:button_click: Could not find lightbulb for ",id)
      end
    end
  end
  def toggle_light_bulb(ip, id, on)
    return self.u.send(ip, 56700, bytes("26000014") + bytes(self.source) + bytes(id)  + bytes("00000000000000000201000000000000000015000000") + bytes(on ? "ffff" : "0000"))
  end
  def every_250ms()
    var packet = self.u.read()
    while packet != nil
      var cmd=packet[32]
      if cmd == 3
        var id = packet[8..13].tohex()
        # Ask for a human-friendly label to show the user
        self.u.send(self.u.remote_ip, 56700, bytes("24000014")+bytes(self.source)+bytes(id)+bytes("00000000000000000301000000000000000017000000"))
      elif cmd == 25
        var id = packet[8..13].tohex()
        var label = string.split(packet[36..-1].asstring(),"\000", 0)[0] # truncate string at its first null..
        self.discovery[id] = [self.u.remote_ip, label]
      end
      packet = self.u.read()
    end
  end
end

var lifx = LifxDriver()
tasmota.add_driver(lifx)
