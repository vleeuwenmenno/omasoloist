"""Exercise real QML JavaScript functions with an offline Node harness.

These checks cover callback ordering; qmlformat separately checks QML syntax.
"""
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
NODE = shutil.which("node")


def function(file, name):
    source = (ROOT / file).read_text()
    start = source.index("function " + name + "(")
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


@unittest.skipUnless(NODE, "Node is required for QML JavaScript checks")
class QmlLogicTests(unittest.TestCase):
    def run_functions(self, file, names, body):
        functions = "\n".join(function(file, name) for name in names)
        assignments = "\n".join("root." + name + " = " + name + ";" for name in names)
        script = "const assert = require('node:assert/strict');\n" + body.replace(
            "INSTALL", "with(root) {\n" + functions + "\n" + assignments + "\n}")
        result = subprocess.run([NODE, "-"], input=script, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_library_refresh_rejects_old_callback(self):
        self.run_functions("LibraryView.qml", ["emptySources", "nextKind", "load"], """
const requests = [];
const root = {
 api: {signedIn:true, call(args, callback) {requests.push({args,callback});}},
 revision:0, loading:false, initialized:true, freshPages:false, retries:0,
 error:'', filter:'', kinds:['playlist','album','artist']
};
Object.defineProperty(root,'playlists',{get() {return root.sources.playlist.items;}});
const list={contentHeight:100,height:50};
const Qt={callLater() {}};
const retryTimer={stop() {},restart() {}};
INSTALL
root.sources=root.emptySources();
root.sources.playlist.items=[{id:'old'}];
root.load(false);
root.load(true,true);
assert.deepEqual(requests[1].args,['--fresh','playlists','0']);
requests[0].callback({ok:true,items:[{id:'older'}],next:false});
assert.deepEqual(root.sources.playlist.items,[]);
assert.equal(root.loading,true);
requests[1].callback({ok:true,items:[{id:'fresh'}],next:true});
assert.deepEqual(root.sources.playlist.items.map(x=>x.id),['fresh']);
root.load(false);
assert.deepEqual(requests[2].args,['--fresh','playlists','1']);
""")

    def test_collection_change_during_load_does_not_leave_loading_stuck(self):
        self.run_functions("CollectionModel.qml", ["load"], """
const callbacks=[];
const root={collection:{kind:'playlist',id:'A'},api:{signedIn:true,call(args,cb){callbacks.push(cb);}},
 revision:0,loading:false,loadedAll:false,tracks:[],total:0,error:'',meta:null,wantAll:false};
const Qt={callLater() {}};
INSTALL
root.load(true);
root.collection={kind:'playlist',id:'B'};
root.load(true);
callbacks[0]({ok:true,items:[{uri:'A'}],total:1,next:false});
assert.equal(root.loading,true);
callbacks[1]({ok:true,items:[{uri:'B'}],total:1,next:false});
assert.equal(root.loading,false);
assert.equal(root.tracks[0].uri,'B');
""")

    def test_likes_expire_and_duplicate_queries_are_coalesced(self):
        self.run_functions("Likes.qml", ["set", "query"], """
let now=1000;
Date.now=()=>now;
const requests=[];
const uri='spotify:track:A';
const root={api:{signedIn:true,waitFor(){return 0;},call(args,callback){requests.push({args,callback});}},
 known:{[uri]:false},checkedAt:{[uri]:1000},pending:{},checking:{},versions:{},revision:0,nextQuery:0};
INSTALL
root.query([uri]);
assert.equal(requests.length,0);
now=31000;
root.query([uri,uri]);
root.query([uri]);
assert.equal(requests.length,1);
assert.deepEqual(requests[0].args,['liked-contains',uri]);
requests[0].callback({ok:true,liked:{[uri]:true}});
assert.equal(root.known[uri],true);
assert.equal(root.checkedAt[uri],31000);
""")

    def test_like_read_cannot_overwrite_optimistic_mutation(self):
        self.run_functions("Likes.qml", ["set", "query", "isLiked", "toggle"], """
const requests=[];
const uri='spotify:track:A';
const root={api:{signedIn:true,waitFor(){return 0;},call(args,callback){requests.push({args,callback});}},
 known:{[uri]:false},checkedAt:{},pending:{},checking:{},versions:{},revision:0,nextQuery:0,libraryChanged(){}};
INSTALL
root.query([uri]);
root.toggle(uri);
assert.equal(root.known[uri],true);
requests[1].callback({ok:true});
requests[0].callback({ok:true,liked:{[uri]:false}});
assert.equal(root.known[uri],true);
assert.equal(root.pending[uri],undefined);
""")

    def test_disk_cache_hit_does_not_extend_like_freshness(self):
        self.run_functions("Likes.qml", ["set", "query"], """
let now=100000;
Date.now=()=>now;
const requests=[];
const uri='spotify:track:A';
const root={api:{signedIn:true,waitFor(){return 0;},call(args,callback){requests.push({args,callback});}},
 known:{},checkedAt:{},pending:{},checking:{},versions:{},revision:0,nextQuery:0};
INSTALL
root.query([uri]);
requests[0].callback({ok:true,liked:{[uri]:true},cacheAge:29});
assert.equal(root.checkedAt[uri],71000);
now=101001;
root.query([uri]);
assert.equal(requests.length,2);
""")

    def test_account_reset_rejects_pending_like_reads(self):
        self.run_functions("Likes.qml", ["set", "query", "reset"], """
let callback;
const uri='spotify:track:A';
const root={api:{signedIn:true,waitFor(){return 0;},call(args,cb){callback=cb;}},
 known:{},checkedAt:{},pending:{},checking:{},versions:{},revision:0,nextQuery:0};
INSTALL
root.query([uri]);
root.reset();
callback({ok:true,liked:{[uri]:true}});
assert.deepEqual(root.known,{});
""")

    def test_remote_player_coalesces_queue_reads_and_honors_cooldown(self):
        self.run_functions("RemotePlayer.qml", ["poll", "refreshQueue"], """
const requests=[];
const root={api:{call(args,callback){requests.push({args,callback});}},polling:true,pollBusy:false,
 queueBusy:false,queueWanted:true,lastQueuePoll:0,retryUntil:0,revision:0,apply(){},queueUpcoming:[]};
const Entity={fromTrack:t=>t};
INSTALL
root.poll();
root.refreshQueue();
root.poll();
assert.deepEqual(requests.map(x=>x.args[0]),['player','queue']);
requests[0].callback({ok:false,rateLimited:true,retryAfter:60});
requests[1].callback({ok:true,upcoming:[]});
root.poll();
root.refreshQueue();
assert.equal(requests.length,2);
""")

    def test_session_change_resets_before_reenabling_signed_in_views(self):
        self.run_functions("SpotifyApi.qml", ["applyStatus"], """
const states=[];
const root={session:'A',sessionRevision:0,signedIn:true,hasClientId:true,configFile:'',redirectUri:'',missingScopes:[],checked:true,
 sessionReset(){states.push(root.signedIn);}};
INSTALL
root.applyStatus({session:'B',signedIn:true,hasClientId:true,configFile:'',redirectUri:'',missingScopes:[]});
assert.deepEqual(states,[false]);
assert.equal(root.signedIn,true);
assert.equal(root.sessionRevision,1);
""")

    def test_cooldown_countdown_uses_elapsed_time(self):
        self.run_functions("SpotifyApi.qml", ["waitFor"], """
Date.now=()=>15000;
const root={limits:[{scope:'global',endpoint:'all',seconds:60}],limitsUpdatedAt:1000};
INSTALL
assert.equal(root.waitFor('/me/player'),46);
Date.now=()=>62000;
assert.equal(root.waitFor('/me/player'),0);
""")

    def test_unexpected_signout_resets_cached_ui_session(self):
        self.run_functions("SpotifyApi.qml", ["applyStatus", "call"], """
let finish;
let resets=0;
let result;
const runner={createObject(){return {done:{connect(cb){finish=cb;}},destroy(){},running:false};}};
const limitsSoon={restart(){}};
const root={session:'A',sessionRevision:0,signedIn:true,hasClientId:true,helper:'offline',
 configFile:'offline-config',redirectUri:'offline',missingScopes:[],checked:true,limits:[],
 sessionReset(){resets++;}};
INSTALL
root.call(['me'],r=>{result=r;});
finish({ok:false,error:'Not signed in to Spotify.'});
assert.equal(root.signedIn,false);
assert.equal(root.session,'');
assert.equal(resets,1);
assert.equal(result.ok,false);
""")
