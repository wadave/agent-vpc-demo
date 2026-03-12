// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

(function () {
  "use strict";

  const messagesEl = document.getElementById("messages");
  const form = document.getElementById("chat-form");
  const input = document.getElementById("chat-input");
  const sendBtn = document.getElementById("send-btn");
  const statusDot = document.getElementById("status-indicator");

  let userId = localStorage.getItem("chat_user_id");
  if (!userId) {
    userId = crypto.randomUUID();
    localStorage.setItem("chat_user_id", userId);
  }

  let sessionId = null;
  let isSending = false;

  // --- Session management ---

  async function ensureSession() {
    if (sessionId) return;
    const resp = await fetch("/api/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_id: userId }),
    });
    if (!resp.ok) throw new Error("Failed to create session");
    const data = await resp.json();
    sessionId = data.id;
  }

  // --- DOM helpers ---

  function addMessage(role, text) {
    const wrapper = document.createElement("div");
    wrapper.className = `message ${role}`;

    const bubble = document.createElement("div");
    bubble.className = "message-bubble";
    bubble.textContent = text;
    wrapper.appendChild(bubble);

    if (role === "agent") {
      wrapper.appendChild(createFeedbackRow());
    }

    messagesEl.appendChild(wrapper);
    messagesEl.scrollTop = messagesEl.scrollHeight;
    return bubble;
  }

  function addTypingIndicator() {
    const wrapper = document.createElement("div");
    wrapper.className = "message agent";
    wrapper.id = "typing";

    const indicator = document.createElement("div");
    indicator.className = "typing-indicator";
    for (let i = 0; i < 3; i++) {
      indicator.appendChild(document.createElement("span"));
    }
    wrapper.appendChild(indicator);

    messagesEl.appendChild(wrapper);
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  function removeTypingIndicator() {
    const el = document.getElementById("typing");
    if (el) el.remove();
  }

  function createFeedbackRow() {
    const row = document.createElement("div");
    row.className = "feedback-row";

    const thumbsUp = document.createElement("button");
    thumbsUp.className = "feedback-btn";
    thumbsUp.textContent = "\u{1F44D}";
    thumbsUp.title = "Good response";

    const thumbsDown = document.createElement("button");
    thumbsDown.className = "feedback-btn";
    thumbsDown.textContent = "\u{1F44E}";
    thumbsDown.title = "Bad response";

    function handleFeedback(score, selected) {
      thumbsUp.classList.remove("selected");
      thumbsDown.classList.remove("selected");
      selected.classList.add("selected");
      sendFeedback(score);
    }

    thumbsUp.addEventListener("click", () => handleFeedback(1, thumbsUp));
    thumbsDown.addEventListener("click", () => handleFeedback(0, thumbsDown));

    row.appendChild(thumbsUp);
    row.appendChild(thumbsDown);
    return row;
  }

  // --- API calls ---

  async function sendFeedback(score) {
    try {
      await fetch("/api/feedback", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          score,
          user_id: userId,
          session_id: sessionId,
          text: "",
        }),
      });
    } catch (e) {
      console.error("Feedback failed:", e);
    }
  }

  async function sendMessage(text) {
    if (isSending || !text.trim()) return;
    isSending = true;
    sendBtn.disabled = true;
    statusDot.className = "status-dot loading";

    addMessage("user", text);
    input.value = "";
    addTypingIndicator();

    try {
      await ensureSession();

      const body = {
        app_name: "backend",
        user_id: userId,
        session_id: sessionId,
        new_message: {
          role: "user",
          parts: [{ text }],
        },
        streaming: true,
      };

      const resp = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });

      if (!resp.ok) throw new Error(`Server error: ${resp.status}`);

      removeTypingIndicator();

      // Parse SSE stream
      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let agentBubble = null;
      let agentText = "";
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop(); // keep incomplete line in buffer

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          const jsonStr = line.slice(6).trim();
          if (!jsonStr) continue;

          try {
            const event = JSON.parse(jsonStr);
            const content = event.content;
            if (!content || !content.parts) continue;

            for (const part of content.parts) {
              if (!part.text) continue;
              if (!agentBubble) {
                agentBubble = addMessage("agent", "");
              }
              agentText += part.text;
              agentBubble.textContent = agentText;
              messagesEl.scrollTop = messagesEl.scrollHeight;
            }
          } catch {
            // skip malformed events
          }
        }
      }

      // If no text was received, show a fallback
      if (!agentBubble) {
        addMessage("agent", "No response received.");
      }
    } catch (err) {
      removeTypingIndicator();
      addMessage("agent", `Error: ${err.message}`);
      console.error(err);
    } finally {
      isSending = false;
      sendBtn.disabled = false;
      statusDot.className = "status-dot connected";
      input.focus();
    }
  }

  // --- Event listeners ---

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    sendMessage(input.value);
  });

  // Allow Enter to send, Shift+Enter for newline (if upgraded to textarea)
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendMessage(input.value);
    }
  });
})();
