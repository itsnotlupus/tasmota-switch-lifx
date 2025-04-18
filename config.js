// whitespaced version of the js script embedded in config page, and therefore human readable
// run ./build.sh to inject a minified version in lifx_driver.be
(
  (
    c = 5, 
    wt = 125, 
    g = '+json.dump(persist.lifx_group)+' ?? [], 
    i = '+json.dump(self.discovery)+', 
    $ = i => document.querySelector(i),
    $$ = i => [...document.querySelectorAll(i)],
    e = s => s.replace(/[&<>\'"]/g, c => `&#x${c.charCodeAt().toString(16)};`), 
    s = (t,c) => $(t).onchange = () => $(c).style.display=$(t).value=="custom"?"":"none",
    l = j => { 
      Object.entries(j).forEach(([id, [ip, label]]) => 
        $("#"+id) 
          ? $(`label[for="${id}"]`).textContent = label
          : $`#t`.append(Object.assign(document.createElement`tr`, { 
            innerHTML: `<td><input id="${e(id)}" name="${e(id)}" ${g.includes(id) ? "checked" : ""} type="checkbox"></td><td><label for="${e(id)}">${e(label)}</label></td><td>${e(ip)}</label></td>` 
          }))
      );
      $$`tbody label`.sort((l1, l2) => l1.textContent.localeCompare(l2.textContent)).forEach(l => $`#t`.append(l.parentElement.parentElement)) 
    },
    f = _ => setTimeout(async _ => { 
      if (!c--) return; 
      f(); 
      l(await (await fetch("?j=1")).json()) 
    }, wt *= 2)
  ) => { 
    $`#f`.onsubmit = _ => $`#f`.group.value = $$`tbody [type="checkbox"]`.filter(i => i.checked).map(i => i.name).join();
    s("#t1","#c1");
    s("#t2","#c2");
    l(i); 
    f() 
  }
)()