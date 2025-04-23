// whitespaced and commented version of the js script embedded in config page
// run ./build.sh to inject a minified version in lifx_driver.be
(
  (
    // refresh the discovery json feed 5 times
    c = 5, 
    // with exponential backoff, starting at 250ms and ending at 4s.
    wt = 125, 
    // the '+...+' shape inserts content from the Berry code
    g = '+json.dump(persist.lifx_group)+' ?? [], 
    i = '+json.dump(self.discovery)+', 
    // $ and $$ are singular and plural shortcuts to grab elements from CSS selectors
    $ = i => document.querySelector(i),
    $$ = i => [...document.querySelectorAll(i)],
    // e escapes unsafe characters into html entities
    e = s => s.replace(/[&<>\'"]/g, c => `&#x${c.charCodeAt().toString(16)};`), 
    // hook an event on <select> tag to show a custom text field
    s = (t,c) => $(t).onchange = () => $(c).style.display=$(t).value=="custom"?"":"none",
    // get a string of comma-separated selected devices' ids
    w = _=>$$`tbody [type="checkbox"]`.filter(i => i.checked).map(i => i.name).join(),
    // hook a button to test the selected lights
    b = i => $("#"+i).onclick = _=> fetch(`?${i}=1&ids=${w()}&src=${$`[name="setgrp"]`.value}`),
    // process a "discovery" json payload and inject it into the markup.
    l = j => { 
      Object.entries(j).forEach(([id, [ip, label]]) => 
        $("#"+id) 
          // only update labels for devices that are already listed
          ? $(`label[for="${id}"]`).textContent = label
          // create a new table row for each new device found
          : $`#t`.append(Object.assign(document.createElement`tr`, { 
            innerHTML: `<td><input id="${e(id)}" name="${e(id)}" ${g.includes(id) ? "checked" : ""} type="checkbox"></td><td><label for="${e(id)}">${e(label)}</label></td><td>${e(ip)}</label></td>` 
          }))
      );
      // sort table by device display name
      $$`tbody label`.sort((l1, l2) => l1.textContent.localeCompare(l2.textContent)).forEach(l => $`#t`.append(l.parentElement.parentElement)) 
    },
    // discovery feed scheduled fetching code
    f = _ => setTimeout(async _ => { 
      if (!c--) return; 
      f(); 
      l(await (await fetch("?j=1")).json()) 
    }, wt *= 2)
  ) => { 
    // group selected devices into one field before submitting, to deal with a berry api limitation
    $`#f`.onsubmit = _ => $`#f`.group.value = w();
    // hook events on trigger fields
    s("#t1","#c1");
    s("#t2","#c2");
    // hook events on test buttons
    b("tl");
    b("fb");
    // hook options checkboxes: make the 3d checkbox conditional on the 2d one being set
    $("#o2").onchange = (e,w=$("#o3")) => (w.disabled=!$("#o2").checked)&&(w.checked=false);
    // process the first discovery json payload embedded in the script
    l(i); 
    // schedule fetching updated discovery feeds
    f()
  }
)()