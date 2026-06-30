// CommentToggler — macOS port
// Original Windows plugin: "Comment Toggler" by ScienceDiscoverer (GPL/Copyleft 2023).
// https://github.com/ScienceDiscoverer/CommentToggler
//
// Smart per-language comment toggling over the current selection(s): single-line,
// multi-line line-comment (indent-aware), and block-comment modes, with multi-
// selection support. The toggle logic is ported verbatim from the Windows source;
// only the platform layer changes (Win32/HBITMAP → AppKit, SendMessage →
// nppData._sendMessage, langs.xml char-parser → NSXMLDocument).
//
// Comment tags come from langs.model.xml (shipped in resources/, same data the
// host uses). NPPM_GETCURRENTLANGTYPE returns canonical Windows L_* ids, so the
// L_*-indexed name table from the original is preserved.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <dlfcn.h>
#include <cstring>
#include <map>
#include <string>
#include <vector>

typedef unsigned long long ui64;
typedef long long i64;
static const ui64 NPOS = (ui64)-1;

#define FIND_BEFORE 0x0
#define FIND_AFTER  0x1
#define CLOSING     0x0
#define OPENING     0x2
#define L_USER_LANG 15   // Windows L_USER enum value

static const char *PLUGIN_NAME = "Comment Toggler";
static const int nbFunc = 2;

// L_*-indexed language names (matches langs.model.xml <Language name="…">).
static const char *kLangNames[] = {
    "normal","php","c","cpp","cs","objc","java","rc","html","xml","makefile",
    "pascal","batch","ini","nfo","L_USER","asp","sql","vb","L_JS","css","perl",
    "python","lua","tex","fortran","bash","actionscript","nsis","tcl","lisp",
    "scheme","asm","diff","props","postscript","ruby","smalltalk","vhdl","kix",
    "autoit","caml","ada","verilog","matlab","haskell","inno","searchResult",
    "cmake","yaml","cobol","gui4cli","d","powershell","r","jsp","coffeescript",
    "json","javascript","fortran77","baanc","srec","ihex","tehex","swift","asn1",
    "avs","blitzbasic","purebasic","freebasic","csound","erlang","escript","forth",
    "latex","mmixal","nim","nncrontab","oscript","rebol","registry","rust","spice",
    "txt2tags","visualprolog","typescript","L_EXTERNAL"
};
static const int kLangCount = (int)(sizeof(kLangNames) / sizeof(kLangNames[0]));

namespace {

struct Tags { std::string line, beg, end; };
struct Selection { ui64 beg, end, idx; };

NppData nppData;
FuncItem funcItem[nbFunc];
ShortcutKey gShortcut;  // reserved; left unbound to avoid macOS Cmd-key conflicts

NppHandle gSci = 0;
std::map<std::string, Tags> gTagDB;
bool gDBLoaded = false;

std::string gLine, gBeg, gEnd;        // current language's comment tags
std::vector<Selection> gSelects;

// ── platform helpers ────────────────────────────────────────────────────────
intptr_t sci(uint32_t msg, ui64 wp = 0, ui64 lp = 0) {
    return nppData._sendMessage(gSci, msg, (uintptr_t)wp, (intptr_t)lp);
}
void updateSci() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    gSci = (which == 0) ? nppData._scintillaMainHandle
         : (which == 1) ? nppData._scintillaSecondHandle : 0;
}

std::string resourceDir() {
    Dl_info info;
    if (dladdr((const void *)&resourceDir, &info) && info.dli_fname) {
        std::string p(info.dli_fname);
        size_t s = p.find_last_of('/');
        return (s == std::string::npos ? std::string(".") : p.substr(0, s)) + "/resources";
    }
    return "resources";
}

// Parse langs.model.xml once → name → comment tags.
void loadLangDB() {
    if (gDBLoaded) return;
    gDBLoaded = true;
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:(resourceDir() + "/langs.model.xml").c_str()];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return;
        NSError *err = nil;
        NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:&err];
        if (!doc) return;
        for (NSXMLElement *L in [doc nodesForXPath:@"//Languages/Language" error:&err]) {
            NSXMLNode *n = [L attributeForName:@"name"];
            if (!n) continue;
            Tags t;
            NSXMLNode *cl = [L attributeForName:@"commentLine"];
            NSXMLNode *cs = [L attributeForName:@"commentStart"];
            NSXMLNode *ce = [L attributeForName:@"commentEnd"];
            if (cl) t.line = [[cl stringValue] UTF8String];   // entities already decoded
            if (cs) t.beg  = [[cs stringValue] UTF8String];
            if (ce) t.end  = [[ce stringValue] UTF8String];
            gTagDB[std::string([[n stringValue] UTF8String])] = t;
        }
    }
}

// ── ported Scintilla logic (verbatim semantics) ─────────────────────────────
ui64 fnd1stNonSp(ui64 line, ui64 *h_sp = nullptr) {
    ui64 line_l = (ui64)sci(SCI_LINELENGTH, line);
    std::vector<char> buf(line_l + 1, 0);
    sci(SCI_GETLINE, line, (ui64)buf.data());
    if (h_sp) *h_sp = 0;
    for (ui64 i = 0; i < line_l; ++i) {
        if (buf[i] != '\t' && buf[i] != ' ') {
            if (buf[i] == '\r' || buf[i] == '\n') break;
            return i;
        }
        if (h_sp) ++(*h_sp);
    }
    return NPOS;
}

bool rangeEquals(ui64 cpMin, ui64 cpMax, const std::string &probe) {
    if (probe.empty()) return false;
    std::vector<char> buf((size_t)(cpMax - cpMin) + 1, 0);
    Sci_TextRangeFull tr;
    tr.chrg.cpMin = (Sci_Position)cpMin;
    tr.chrg.cpMax = (Sci_Position)cpMax;
    tr.lpstrText = buf.data();
    sci(SCI_GETTEXTRANGEFULL, 0, (ui64)&tr);
    return probe == buf.data();
}

bool isComment(ui64 pos) {
    if (pos == NPOS) return false;
    return rangeEquals(pos, pos + gLine.size(), gLine);
}

bool isBlockComm(ui64 pos, ui64 mode) {
    const std::string &t = (mode & OPENING) ? gBeg : gEnd;
    ui64 a = (mode & FIND_AFTER) ? pos : pos - t.size();
    ui64 b = (mode & FIND_AFTER) ? pos + t.size() : pos;
    return rangeEquals(a, b, t);
}

bool isLineBeg(ui64 pos) {
    ui64 line = (ui64)sci(SCI_LINEFROMPOSITION, pos);
    ui64 lb = (ui64)sci(SCI_POSITIONFROMLINE, line);
    if (pos == lb) return true;
    std::vector<char> buf((size_t)(pos - lb) + 1, 0);
    Sci_TextRangeFull tr; tr.chrg.cpMin = (Sci_Position)lb; tr.chrg.cpMax = (Sci_Position)pos; tr.lpstrText = buf.data();
    sci(SCI_GETTEXTRANGEFULL, 0, (ui64)&tr);
    for (ui64 i = (pos - lb); i-- > 0;)
        if (buf[i] != '\t' && buf[i] != ' ') return false;
    return true;
}

bool isLineEnd(ui64 pos) {
    ui64 line = (ui64)sci(SCI_LINEFROMPOSITION, pos);
    ui64 le = (ui64)sci(SCI_GETLINEENDPOSITION, line);
    ui64 lb = (ui64)sci(SCI_POSITIONFROMLINE, line);
    if (le == (ui64)sci(SCI_GETTEXTLENGTH)) return true;
    if (pos == le || pos == lb) return true;
    std::vector<char> buf((size_t)(le - pos) + 1, 0);
    Sci_TextRangeFull tr; tr.chrg.cpMin = (Sci_Position)pos; tr.chrg.cpMax = (Sci_Position)le; tr.lpstrText = buf.data();
    sci(SCI_GETTEXTRANGEFULL, 0, (ui64)&tr);
    for (ui64 i = 0; i < (le - pos); ++i)
        if (buf[i] != '\t' && buf[i] != ' ') return false;
    return true;
}

bool isPosBegLine(ui64 pos, ui64 line) { return pos == (ui64)sci(SCI_POSITIONFROMLINE, line); }
void insertTabs(ui64 amount, ui64 pos) { for (ui64 i = 0; i < amount; ++i) sci(SCI_INSERTTEXT, pos, (ui64) "\t"); }

i64 togSingSelLineComm(ui64 sel_s, ui64 sel_e, ui64 sel_i) {
    ui64 line = (ui64)sci(SCI_LINEFROMPOSITION, sel_s);
    ui64 non_sp = fnd1stNonSp(line);
    ui64 abs_pos = NPOS;
    if (non_sp == NPOS) non_sp = sel_s;
    else abs_pos = non_sp + (ui64)sci(SCI_POSITIONFROMLINE, line);

    if (isComment(abs_pos)) {
        sci(SCI_DELETERANGE, abs_pos, gLine.size());
        sel_s -= gLine.size(); sel_e -= gLine.size();
        gSelects[sel_i].beg = sel_s; gSelects[sel_i].end = sel_e;
        return -(i64)gLine.size();
    }
    sci(SCI_INSERTTEXT, abs_pos, (ui64)gLine.c_str());
    sel_s += gLine.size(); sel_e += gLine.size();
    gSelects[sel_i].beg = sel_s; gSelects[sel_i].end = sel_e;
    return (i64)gLine.size();
}

i64 togMultiSelLineComm(ui64 sel_s, ui64 sel_e, ui64 sel_i) {
    i64 ch_changed = 0;
    ui64 line0 = (ui64)sci(SCI_LINEFROMPOSITION, sel_s);
    ui64 line1 = (ui64)sci(SCI_LINEFROMPOSITION, sel_e);
    if (fnd1stNonSp(line0) == NPOS) ++line0;
    if (isPosBegLine(sel_e, line1)) --line1;

    ui64 min_indent = NPOS;
    for (ui64 i = line0; i <= line1; ++i) { ui64 ind = fnd1stNonSp(i); if (ind < min_indent) min_indent = ind; }

    ui64 h_sp = 0;
    ui64 line0_beg = (ui64)sci(SCI_POSITIONFROMLINE, line0);
    ui64 line0_abs_indent = fnd1stNonSp(line0, &h_sp) + line0_beg;
    ui64 line0_abs_pos = line0_beg + min_indent;
    bool to_uncomment = isComment(line0_abs_indent);
    ui64 tot_l_com = 0, tot_l_uncom = 0;

    if (to_uncomment) { sci(SCI_DELETERANGE, line0_abs_indent, gLine.size()); ch_changed -= (i64)gLine.size(); ++tot_l_uncom; }
    else { sci(SCI_INSERTTEXT, line0_abs_pos, (ui64)gLine.c_str()); ch_changed += (i64)gLine.size(); ++tot_l_com; }

    if (h_sp > 0 && sel_s > line0_abs_pos) sel_s = to_uncomment ? line0_abs_indent : line0_abs_pos;

    ui64 addt_ins = 0;
    for (ui64 i = line0 + 1; i <= line1; ++i) {
        ui64 line_beg = (ui64)sci(SCI_POSITIONFROMLINE, i);
        ui64 abs_pos = min_indent + line_beg;
        ui64 non_sp = fnd1stNonSp(i, &h_sp);
        if (non_sp == NPOS) {
            if (min_indent > h_sp) { ui64 need = min_indent - h_sp; addt_ins += need; insertTabs(need, line_beg); ch_changed += (i64)need; }
        }
        ui64 abs_indent = non_sp + line_beg;
        if (to_uncomment) {
            if (!isComment(abs_indent)) continue;
            sci(SCI_DELETERANGE, abs_indent, gLine.size()); ch_changed -= (i64)gLine.size(); ++tot_l_uncom;
        } else { sci(SCI_INSERTTEXT, abs_pos, (ui64)gLine.c_str()); ch_changed += (i64)gLine.size(); ++tot_l_com; }
    }

    sel_e = to_uncomment ? sel_e - tot_l_uncom * gLine.size() : sel_e + tot_l_com * gLine.size();
    sel_e += addt_ins;
    gSelects[sel_i].beg = sel_s; gSelects[sel_i].end = sel_e;
    return ch_changed;
}

i64 togBlockComm(ui64 sel_s, ui64 sel_e, ui64 sel_i) {
    i64 ch_changed = 0;
    bool unc_beg = false, unc_end = false;
    ui64 obc = sel_s, cbc = sel_e;

    if (isBlockComm(sel_s, FIND_AFTER | OPENING)) unc_beg = true;
    else if (isBlockComm(sel_s, FIND_BEFORE | OPENING)) { obc -= gBeg.size(); unc_beg = true; }

    if (isBlockComm(sel_e, FIND_BEFORE | CLOSING)) { cbc -= gEnd.size(); unc_end = true; }
    else if (isBlockComm(sel_e, FIND_AFTER | CLOSING)) unc_end = true;

    if (unc_beg && unc_end) {
        sci(SCI_DELETERANGE, obc, gBeg.size()); ch_changed -= (i64)gBeg.size();
        cbc -= gBeg.size();
        sci(SCI_DELETERANGE, cbc, gEnd.size()); ch_changed -= (i64)gEnd.size();
        sel_s -= sel_s - obc; sel_e -= gBeg.size(); sel_e -= sel_e - cbc;
    } else {
        sci(SCI_INSERTTEXT, obc, (ui64)gBeg.c_str()); ch_changed += (i64)gBeg.size();
        cbc += gBeg.size();
        sci(SCI_INSERTTEXT, cbc, (ui64)gEnd.c_str()); ch_changed += (i64)gEnd.size();
        sel_s += gBeg.size(); sel_e += gBeg.size();
    }
    gSelects[sel_i].beg = sel_s; gSelects[sel_i].end = sel_e;
    return ch_changed;
}

i64 doToggleComment(ui64 sel_s, ui64 sel_e, ui64 sel_i) {
    if (!gLine.empty()) {
        if (sel_s == sel_e) return togSingSelLineComm(sel_s, sel_e, sel_i);
        if (!gBeg.empty() && !gEnd.empty())
            if (!isLineBeg(sel_s) || !isLineEnd(sel_e)) return togBlockComm(sel_s, sel_e, sel_i);
        return togMultiSelLineComm(sel_s, sel_e, sel_i);
    }
    if (!gBeg.empty() && !gEnd.empty()) return togBlockComm(sel_s, sel_e, sel_i);
    return 0;
}

// ── commands ────────────────────────────────────────────────────────────────
void toggleComment() {
    @autoreleasepool {
        loadLangDB();
        updateSci();
        if (!gSci) return;

        int lang_t = 0;
        nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTLANGTYPE, 0, (intptr_t)&lang_t);

        if (lang_t == 0) { gLine = ">>> "; gBeg = "["; gEnd = "]"; }     // plain text (as original)
        else if (lang_t == L_USER_LANG) { gLine.clear(); gBeg.clear(); gEnd.clear(); } // UDL: not yet supported
        else if (lang_t >= 0 && lang_t < kLangCount) {
            auto it = gTagDB.find(kLangNames[lang_t]);
            if (it != gTagDB.end()) { gLine = it->second.line; gBeg = it->second.beg; gEnd = it->second.end; }
            else { gLine.clear(); gBeg.clear(); gEnd.clear(); }
        } else { gLine.clear(); gBeg.clear(); gEnd.clear(); }

        if (gLine.empty() && (gBeg.empty() || gEnd.empty())) return;  // nothing to toggle

        ui64 sel_n = (ui64)sci(SCI_GETSELECTIONS);
        if (sel_n == 0) return;
        gSelects.assign(sel_n, Selection{});
        for (ui64 i = 0; i < sel_n; ++i) {
            gSelects[i].beg = (ui64)sci(SCI_GETSELECTIONNSTART, i);
            gSelects[i].end = (ui64)sci(SCI_GETSELECTIONNEND, i);
            gSelects[i].idx = i;
        }
        for (ui64 i = 0; i < sel_n; ++i)        // insertion sort by start (as original)
            for (ui64 j = i + 1; j < sel_n; ++j)
                if (gSelects[j].beg < gSelects[i].beg) std::swap(gSelects[i], gSelects[j]);

        sci(SCI_BEGINUNDOACTION);
        i64 ch_ins = 0;
        for (ui64 i = 0; i < sel_n; ++i) {
            ui64 ss = gSelects[i].beg + ch_ins;
            ui64 se = gSelects[i].end + ch_ins;
            ch_ins += doToggleComment(ss, se, i);
        }
        if (gSelects[0].end < gSelects[0].beg) std::swap(gSelects[0].end, gSelects[0].beg);
        sci(SCI_SETSELECTION, gSelects[0].end, gSelects[0].beg);
        for (ui64 i = 1; i < sel_n; ++i) {
            if (gSelects[i].end < gSelects[i].beg) std::swap(gSelects[i].end, gSelects[i].beg);
            sci(SCI_ADDSELECTION, gSelects[i].end, gSelects[i].beg);
        }
        sci(SCI_ENDUNDOACTION);
        gSelects.clear();
    }
}

void visitHomepage() {
    @autoreleasepool {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/ScienceDiscoverer/CommentToggler"]];
    }
}

} // namespace

// ── plugin exports ───────────────────────────────────────────────────────────
extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    memset(funcItem, 0, sizeof(funcItem));
    strncpy(funcItem[0]._itemName, "Toggle comment", NPP_MENU_ITEM_SIZE - 1);
    funcItem[0]._pFunc = toggleComment;
    funcItem[0]._pShKey = nullptr;
    strncpy(funcItem[1]._itemName, "Plug-in homepage", NPP_MENU_ITEM_SIZE - 1);
    funcItem[1]._pFunc = visitHomepage;
    funcItem[1]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) { *nbF = nbFunc; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    switch (n->nmhdr.code) {
        case NPPN_TBMODIFICATION:
            // macOS: lParam=0 → host loads toolbar.png / toolbar_dark.png from the plugin dir.
            nppData._sendMessage(nppData._nppHandle, NPPM_ADDTOOLBARICON_FORDARKMODE,
                                 (uintptr_t)funcItem[0]._cmdID, 0);
            break;
        default: break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t m, uintptr_t w, intptr_t l) {
    (void)m; (void)w; (void)l; return 1;
}
