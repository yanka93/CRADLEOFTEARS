
var usernameWasFocused = 0;

if (document.getElementById) {
    // If there's no getElementById, this whole script won't do anything

    var radio_remote = document.getElementById("talkpostfromremote");
    var radio_user = document.getElementById("talkpostfromlj");
    var radio_anon = document.getElementById("talkpostfromanon");
    var radio_oidlo = document.getElementById("talkpostfromoidlo");
    var radio_ljcoidlo = document.getElementById("talkpostfromljcoidlo");
    var radio_oidli = document.getElementById("talkpostfromoidli");
    var radio_ljcoidli = document.getElementById("talkpostfromljcoidli");

    var check_login = document.getElementById("logincheck");
    var sel_pickw = document.getElementById("prop_picture_keyword");
    var commenttext = document.getElementById("commenttext");

    var form = document.getElementById("postform");

    var username = form.userpost;
    username.onfocus = function () { usernameWasFocused = 1; }
    var password = form.password;

    var oidurl = document.getElementById("oidurl");
    var ljc_oidurl = document.getElementById("ljc_oidurl");
    var oid_more = document.getElementById("oid_more");
    var ljc_oid_more = document.getElementById("ljc_oid_more");
    var lj_more = document.getElementById("lj_more");
    var ljuser_row = document.getElementById("ljuser_row");
    var otherljuser_row = document.getElementById("otherljuser_row");
    var oidlo_row = document.getElementById("oidlo");
    var ljc_oidlo_row = document.getElementById("ljc_oidlo");
    var oidli_row = document.getElementById("oidli");
    var ljc_oidli_row = document.getElementById("ljc_oidli");

    var remotef = document.getElementById("cookieuser");
    var remote;
    if (remotef) {
        remote = remotef.value;
    }

    var subjectIconField = document.getElementById("subjectIconField");
    var subjectIconImage = document.getElementById("subjectIconImage");

    var subject_field = document.getElementById("subject");
    var subject_nohtml = document.getElementById("ljnohtmlsubj");
    subject_nohtml.style.display = 'none';
}

var apicurl = "";
var picprevt;

if (! sel_pickw) {
    // make a fake sel_pickw to play with later
    sel_pickw = new Object();
}

function handleRadios(sel) {
    password.disabled = check_login.disabled = (sel != 2);
    if (password.disabled) password.value='';

    // Anonymous
    if (sel == 0) {
        if (radio_anon.checked != 1) {
            radio_anon.checked = 1;
        }
    }

    // Remote LJ User
    if (sel == 1) {
        if (radio_remote.checked != 1) {
            radio_remote.checked = 1;
        }
    }

    // LJ User
    if (sel == 2) {
        if (ljuser_row) {
            ljuser_row.style.display = 'none';
        }
        if (lj_more) {
                lj_more.style.display = '';
        }
        username.focus();

        if (radio_user.checked != 1) {
            radio_user.checked = 1;
        }

    } else {
        if (lj_more) {
            lj_more.style.display = 'none';
        }
    }

    // OpenID
    if (oid_more) {
        if (sel == 3) {
            oid_more.style.display = '';
            oidurl.focus();
            if (oidli_row) {
               oidli_row.style.display = 'none';
            }
            oidlo_row.style.display = '';

            if (radio_oidlo.checked != 1) {
                radio_oidlo.checked = 1;
            }

        } else if (sel == 4) {
            if (oidlo_row) {
               oidlo_row.style.display = 'none';
            }
            oidli_row.style.display = '';
            oid_more.style.display = 'none';

            if (radio_oidli.checked != 1) {
                radio_oidli.checked = 1;
            }
        } else {
            oid_more.style.display = 'none';
        }
    }
    
    // LiveJournal user
    if (ljc_oid_more) {
      if (sel == 103) {
        ljc_oidlo_row.style.display = '';
        ljc_oid_more.style.display = '';

        if (ljc_oidli_row) {
          ljc_oidli_row.style.display = 'none';
        }

        if (ljc_oidurl.value == "") {
          ljc_oidurl.focus();
        }

        if (radio_ljcoidlo.checked != 1) {
          radio_ljcoidlo.checked = 1;
        }
      }
      else if (sel == 104) {
        if (ljc_oidlo_row) {
          ljc_oidlo_row.style.display = 'none';
        }
        ljc_oidli_row.style.display = '';
        ljc_oid_more.style.display = 'none';

        if (radio_ljcoidli.checked != 1) {
          radio_ljcoidli.checked = 1;
        }
      }
      else {
        ljc_oid_more.style.display = 'none';
      }
    }

    if (sel_pickw.disabled = (sel != 1)) sel_pickw.value='';
}

function submitHandler() {
    if (
      remote && username.value == remote &&
      (
        (! radio_anon || ! radio_anon.checked) &&
        (! radio_oidlo || ! radio_oidlo.checked) &&
        (! radio_ljcoidlo || ! radio_ljcoidlo.checked) &&
        (! radio_ljcoidli || ! radio_ljcoidli.checked)
      )
    ) {
        //  Quietly arrange for cookieuser auth instead, to avoid
        // sending cleartext password.
        password.value = "";
        username.value = "";
        radio_remote.checked = true;
        return true;
    }
    if (usernameWasFocused && username.value && ! radio_user.checked) {
        alert(usermismatchtext);
        return false;
    }
    if (! radio_user.checked) {
        username.value = "";
    }

    return true;
}

if (document.getElementById) {

    if (radio_anon && radio_anon.checked) handleRadios(0);
    if (radio_remote && radio_remote.checked) handleRadios(1);
    if (radio_user && radio_user.checked) handleRadios(2);
    if (radio_oidlo && radio_oidlo.checked) handleRadios(3);
    if (radio_oidli && radio_oidli.checked) handleRadios(4);
    if (radio_ljcoidlo && radio_ljcoidlo.checked) handleRadios(103);
    if (radio_ljcoidli && radio_ljcoidli.checked) handleRadios(104);

    if (radio_remote) {
        radio_remote.onclick = function () {
            handleRadios(1);
        };
        if (radio_remote.checked) handleRadios(1);
    }
    if (radio_user)
        radio_user.onclick = function () {
            handleRadios(2);
        };
    if (radio_anon)
        radio_anon.onclick = function () {
            handleRadios(0);
        };
    if (radio_oidlo)
        radio_oidlo.onclick = function () {
            handleRadios(3);
        };
    if (radio_oidli)
        radio_oidli.onclick = function () {
            handleRadios(4);
        };
    if (radio_ljcoidlo)
        radio_ljcoidlo.onclick = function () {
            handleRadios(103);
        };
    if (radio_ljcoidli)
        radio_ljcoidli.onclick = function () {
            handleRadios(104);
        };
    username.onkeydown = username.onchange = function () {
        if (radio_remote) {
            password.disabled = check_login.disabled = 0;
            if (password.disabled) password.value='';
        } else {
            if (radio_user && username.value != "")
                radio_user.checked = true;
            handleRadios(2);  // update the form
        }
    }
    form.onsubmit = submitHandler;

    document.onload = function () {
        if (radio_anon && radio_anon.checked) handleRadios(0);
        if (radio_user && radio_user.checked) otherLJUser();
        if (radio_remote && radio_remote.checked) handleRadios(1);
        if (radio_oidlo && radio_oidlo.checked) handleRadios(3);
        if (radio_oidli && radio_oidli.checked) handleRadios(4);
        if (radio_ljcoidlo && radio_ljcoidlo.checked) handleRadios(103);
        if (radio_ljcoidli && radio_ljcoidli.checked) handleRadios(104);
    }

}

// toggle subject icon list

function subjectIconListToggle() {
    if (! document.getElementById) { return; }
    var subjectIconList = document.getElementById("subjectIconList");
    if(subjectIconList) {
     if (subjectIconList.style.display != 'block') {
         subjectIconList.style.display = 'block';
     } else {
         subjectIconList.style.display = 'none';
     }
    }
}

// change the subject icon and hide the list

function subjectIconChange(icon) {
    if (! document.getElementById) { return; }
    if (icon) {
        if(subjectIconField) subjectIconField.value=icon.id;
        if(subjectIconImage) {
            subjectIconImage.src=icon.src;
            subjectIconImage.width=icon.width;
            subjectIconImage.height=icon.height;
        }
        subjectIconListToggle();
    }
}

function subjectNoHTML(e) {

   var key;

   key = getKey(e);

   if (key == 60) {
      subject_nohtml.style.display = 'block';
   }
}

function getKey(e) {
   if (window.event) {
      return window.event.keyCode;
   } else if(e) {
      return e.which;
   } else {
      return undefined;
   }
}

function otherLJUser() {
   handleRadios(2);

   otherljuser_row.style.display = '';
   radio_user.checked = 1;
}

function otherOIDUser() {
   handleRadios(3);

   radio_oidlo.checked = 1;
}

function otherLJCOIDUser() {
   handleRadios(103);

   radio_ljcoidlo.checked = 1;
}
