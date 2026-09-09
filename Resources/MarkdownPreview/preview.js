/*
 * The Markdown preview's one first-party script.
 *
 * Written in this repository. It defines the four members the page is driven
 * through — `boot`, `render`, `scrollToLine`, `scrollToAnchor` — and nothing
 * else reaches the
 * global scope: the shell's single inline line calls `boot`, and everything
 * after that arrives as an `evaluateJavaScript` of a source `MarkdownPreviewPage`
 * composed. This file therefore *decides* nothing. It has no opinion about when
 * to render, what to render, or which line is the top one; it is the page's half
 * of two seams whose Swift halves are covered by `swift test`.
 *
 * Three properties are load-bearing and are the reason this is a file rather
 * than a few lines of injected source:
 *
 *  * Auto-detection is off. A fence with no language stays plain — the renderer
 *    emits it as a bare `<pre><code>`, so the selector below cannot reach it,
 *    and highlight.js is never asked to guess. A guess is worse than no colour:
 *    it colours prose as though it were code and does so differently on every
 *    edit.
 *  * A diagram that fails to parse takes down its own block and nothing else.
 *    mermaid throws on a syntax error, so every diagram is rendered inside its
 *    own try/catch and a failure writes mermaid's own message into that block.
 *    An uncaught throw here would abandon the rest of the loop and leave the
 *    remaining diagrams as raw source.
 *  * A render supersedes the one before it. Diagram rendering is asynchronous,
 *    so a keystroke landing mid-flight would otherwise write an old diagram into
 *    a new body. The generation counter is the same rule the Swift model applies
 *    to parses, applied here for the same reason — this is the one place in the
 *    page where two answers can be in flight at once.
 */
(function () {
    "use strict";

    /* The element the rendered body is written into. The shell ships it empty
       and this is the only thing that ever writes to it. */
    var CONTAINER_ID = "content";

    /* Incremented by every `render`. A diagram whose generation is no longer the
       current one is discarded rather than written. */
    var generation = 0;

    /* Distinct per diagram *and* per render, because mermaid keys its internal
       definitions by the id it is given and a repeated id re-uses the previous
       diagram's state. */
    var diagramSequence = 0;

    function container() {
        return document.getElementById(CONTAINER_ID);
    }

    /* The page's colour scheme, as the shell declared it on <html>. mermaid
       needs its own theme name; every other colour in the page comes from the
       custom properties the shell wrote, which this script never reads. */
    function colorScheme() {
        return document.documentElement.getAttribute("data-color-scheme") === "dark" ? "dark" : "light";
    }

    function boot() {
        if (window.hljs) {
            /* The content arriving through `render` was escaped by the Swift
               renderer, so highlight.js's unescaped-HTML warning has nothing to
               warn about and only costs a console line per block. */
            window.hljs.configure({ ignoreUnescapedHTML: true });
        }
        if (window.mermaid) {
            window.mermaid.initialize({
                startOnLoad: false,
                securityLevel: "strict",
                theme: colorScheme() === "dark" ? "dark" : "default",
            });
        }
    }

    /* Replace the body with `bodyHTML`, then re-run the highlighter and the
       diagram renderer over it.

       `bodyHTML` is the markup `MarkdownRenderer` produced: already escaped,
       carrying no raw HTML from the source document (the Core tree has no case
       for it) and no script of any kind. */
    function render(bodyHTML) {
        var element = container();
        if (!element) { return; }

        generation += 1;
        var mine = generation;

        element.innerHTML = bodyHTML;
        highlight(element);
        renderDiagrams(element, mine);
    }

    /* Every fenced block the renderer gave a language to, and only those: a
       fence without one is a bare `<pre><code>` and stays untouched. */
    function highlight(element) {
        if (!window.hljs) { return; }
        var blocks = element.querySelectorAll("code[class^=\"language-\"]");
        for (var i = 0; i < blocks.length; i += 1) {
            try {
                window.hljs.highlightElement(blocks[i]);
            } catch (error) {
                /* A language highlight.js does not carry is not a failure of the
                   page: the block keeps its text and stays uncoloured. */
            }
        }
    }

    function renderDiagrams(element, mine) {
        if (!window.mermaid) { return; }
        var blocks = element.querySelectorAll("pre.mermaid");
        for (var i = 0; i < blocks.length; i += 1) {
            renderDiagram(blocks[i], mine);
        }
    }

    function renderDiagram(block, mine) {
        var source = block.textContent;
        diagramSequence += 1;
        var id = "pisaka-diagram-" + diagramSequence;

        var finish = function (svg) {
            if (mine !== generation || !block.isConnected) { return; }
            block.innerHTML = svg;
            block.classList.add("mermaid-rendered");
        };

        var fail = function (error) {
            if (mine !== generation || !block.isConnected) { return; }
            /* mermaid's own words, as text rather than markup: the source that
               produced them is the user's, and the page states what the renderer
               said about it without becoming a second thing that can fail. */
            block.textContent = String((error && error.message) || error);
            block.classList.add("mermaid-error");
            /* mermaid leaves the temporary element it measured into behind when
               it throws; without this the page grows one orphan per bad edit. */
            var orphan = document.getElementById("d" + id);
            if (orphan && orphan.parentNode) { orphan.parentNode.removeChild(orphan); }
        };

        try {
            var answer = window.mermaid.render(id, source);
            if (answer && typeof answer.then === "function") {
                answer.then(function (result) { finish(result.svg); }, fail);
            } else if (answer && typeof answer.svg === "string") {
                finish(answer.svg);
            }
        } catch (error) {
            fail(error);
        }
    }

    /* Scroll to the last top-level block whose `data-line` is at or before
       `line`, without animation.

       `data-line` is on top-level blocks alone, so `children` is the whole
       candidate set and no descendant walk is needed. A line the page does not
       have simply lands on the nearest one it does, which is what makes the
       editor's own line — a line inside a block, most of the time — a usable
       argument. */
    function scrollToLine(line) {
        var element = container();
        if (!element) { return; }

        var target = null;
        var children = element.children;
        for (var i = 0; i < children.length; i += 1) {
            var value = parseInt(children[i].getAttribute("data-line"), 10);
            if (isNaN(value) || value > line) { continue; }
            target = children[i];
        }
        if (!target) {
            window.scrollTo(0, 0);
            return;
        }

        window.scrollTo(0, target.getBoundingClientRect().top + window.scrollY);
    }

    /* Scroll to the element a fragment names, without animation, or do nothing.

       An `id` lookup and nothing more: the fragment arrives as the document
       spelled it, and no other reading of it — a heading's text, a slug derived
       from one — is invented here. `MarkdownRenderer` emits no `id` today, so a
       fragment lands on nothing and the page stays where it is, which is the
       honest answer for a link into a document that carries no targets. */
    function scrollToAnchor(name) {
        var target = document.getElementById(name);
        if (!target) { return; }
        window.scrollTo(0, target.getBoundingClientRect().top + window.scrollY);
    }

    window.PisakaPreview = {
        boot: boot,
        render: render,
        scrollToLine: scrollToLine,
        scrollToAnchor: scrollToAnchor,
    };
}());
