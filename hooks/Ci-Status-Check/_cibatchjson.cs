// PS5.1 and PS7 have different permissive JSON parsers. Validate RFC8259 syntax
// before materializing either host's objects; no external assembly or execution.
using System;
using System.Collections.Generic;
namespace HookMaker {
    public static class CiBatchJson {
        public static bool IsValid(string text) {
            try { var p = new Parser(text); p.Value(0); p.Space(); return p.AtEnd; }
            catch (FormatException) { return false; }
        }
        private sealed class Parser {
            private readonly string text;
            private int index;
            public Parser(string value) { if (value == null) throw new FormatException(); text = value; }
            public bool AtEnd { get { return index == text.Length; } }
            public void Space() {
                while (index < text.Length && (text[index] == ' ' || text[index] == '\r' || text[index] == '\n' || text[index] == '\t')) index++;
            }
            private bool Take(char c) {
                if (index < text.Length && text[index] == c) { index++; return true; }
                return false;
            }
            private void Need(char c) { if (!Take(c)) throw new FormatException(); }
            public void Value(int depth) {
                if (depth > 64) throw new FormatException();
                Space();
                if (index >= text.Length) throw new FormatException();
                char c = text[index];
                if (c == '"') { String(); return; }
                if (c == '{') {
                    index++; Space(); if (Take('}')) return;
                    do { Space(); String(); Space(); Need(':'); Value(depth + 1); Space(); if (Take('}')) return; Need(','); } while (true);
                }
                if (c == '[') {
                    index++; Space(); if (Take(']')) return;
                    do { Value(depth + 1); Space(); if (Take(']')) return; Need(','); } while (true);
                }
                foreach (string literal in new string[] { "true", "false", "null" }) {
                    if (c == literal[0]) {
                        if (index + literal.Length > text.Length || string.CompareOrdinal(text, index, literal, 0, literal.Length) != 0) throw new FormatException();
                        index += literal.Length; return;
                    }
                }
                Take('-');
                if (!Take('0')) {
                    if (index >= text.Length || text[index] < '1' || text[index] > '9') throw new FormatException();
                    Digits();
                }
                if (Take('.')) { int first = index; Digits(); if (index == first) throw new FormatException(); }
                if (Take('e') || Take('E')) {
                    if (!Take('+')) Take('-');
                    int first = index; Digits(); if (index == first) throw new FormatException();
                }
            }
            private void Digits() { while (index < text.Length && text[index] >= '0' && text[index] <= '9') index++; }
            private void String() {
                Need('"');
                while (index < text.Length) {
                    char c = text[index++];
                    if (c == '"') return;
                    if (c < 32) throw new FormatException();
                    if (c != '\\') continue;
                    if (index >= text.Length) throw new FormatException();
                    c = text[index++];
                    if (c == 'u') {
                        for (int i = 0; i < 4; i++) {
                            if (index >= text.Length) throw new FormatException();
                            c = text[index++];
                            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) throw new FormatException();
                        }
                    }
                    else if (c != '"' && c != '\\' && c != '/' && c != 'b' && c != 'f' && c != 'n' && c != 'r' && c != 't') throw new FormatException();
                }
                throw new FormatException();
            }
        }
    }
}
