const {
  Client, GatewayIntentBits, ActionRowBuilder, ButtonBuilder,
  ButtonStyle, AttachmentBuilder,
} = require("discord.js");
const {
  joinVoiceChannel, VoiceConnectionStatus, EndBehaviorType,
  entersState,
} = require("@discordjs/voice");
const express = require("express");
const fs = require("fs");
const path = require("path");
const os = require("os");
const { execSync } = require("child_process");
const { randomBytes, timingSafeEqual } = require("crypto");
const { Readable, Transform } = require("stream");
const { finished, pipeline } = require("stream/promises");

const TOKEN = process.env.DISCORD_TOKEN;
const CHANNEL_ID = process.env.DISCORD_CHANNEL_ID;
const TRANSCRIBER_URL = process.env.TRANSCRIBER_URL || "http://transcriber:8080";
const PORT = parseInt(process.env.PORT || "3100");
const SHARED_DIR = process.env.SHARED_DIR || "/shared";
const INTERNAL_API_TOKEN = (process.env.INTERNAL_API_TOKEN || "").trim();
const TELEGRAM_FALLBACK_CHATS = (process.env.TELEGRAM_FALLBACK_CHATS || "")
  .split(",")
  .filter(Boolean);
const PENDING_TTL_MS = 60 * 60 * 1000;
const DEFAULT_MAX_ATTACHMENT_BYTES = 100 * 1024 * 1024;
const configuredMaxAttachmentBytes = Number.parseInt(
  process.env.MAX_ATTACHMENT_BYTES || "",
  10,
);
const MAX_ATTACHMENT_BYTES = Number.isSafeInteger(configuredMaxAttachmentBytes)
  && configuredMaxAttachmentBytes > 0
  ? configuredMaxAttachmentBytes
  : DEFAULT_MAX_ATTACHMENT_BYTES;

const PCM_SAMPLE_RATE = 48_000;
const PCM_CHANNELS = 2;
const PCM_BYTES_PER_SAMPLE = 2;
const PCM_BYTES_PER_FRAME = PCM_CHANNELS * PCM_BYTES_PER_SAMPLE;
const PCM_TIMELINE_TOLERANCE_FRAMES = Math.round(PCM_SAMPLE_RATE * 0.06);
const SILENCE_CHUNK = Buffer.alloc(PCM_SAMPLE_RATE * PCM_BYTES_PER_FRAME);

const MODELS = new Map([
  ["g", { id: "gpt-transcribe", label: "GPT Transcribe" }],
  ["d", { id: "gpt-4o-transcribe-diarize", label: "GPT-4o · говорящие" }],
  ["w", { id: "whisper-1", label: "Whisper · таймкоды" }],
]);

const AUDIO_EXTENSIONS = new Set([
  "mp3", "wav", "ogg", "m4a", "flac", "webm", "mp4", "mpeg", "mpga",
]);

if (!TOKEN) {
  console.error("DISCORD_TOKEN is required");
  process.exit(1);
}
if (!CHANNEL_ID) {
  console.error("DISCORD_CHANNEL_ID is required");
  process.exit(1);
}
if (INTERNAL_API_TOKEN.length < 16) {
  console.error("INTERNAL_API_TOKEN must contain at least 16 characters");
  process.exit(1);
}

const INTERNAL_JSON_HEADERS = Object.freeze({
  "Content-Type": "application/json",
  Authorization: `Bearer ${INTERNAL_API_TOKEN}`,
});

// ── State ────────────────────────────────────────────────────

const pendingTasks = new Map();
let recording = null;

// ── Discord bot ──────────────────────────────────────────────

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.GuildVoiceStates,
    GatewayIntentBits.MessageContent,
  ],
});

client.once("clientReady", () => {
  console.log(`Discord bot ready as ${client.user.username}`);
  console.log(`Guilds: ${client.guilds.cache.map(g => g.name).join(", ")}`);
});

client.on("error", (err) => {
  console.error("Bot error:", err);
});

// ── Message handler ──────────────────────────────────────────

client.on("messageCreate", async (msg) => {
  if (msg.author.bot) return;
  if (msg.channel.id !== CHANNEL_ID) return;

  const text = (msg.content || "").trim();

  if (/^!record(?:\s|$)/.test(text)) {
    await cmdRecord(msg);
    return;
  }
  if (text === "!stop") {
    await cmdStop(msg);
    return;
  }

  for (const att of msg.attachments.values()) {
    if (!isAudio(att)) continue;

    const fname = safeAttachmentName(att.name);
    const sizeMB = ((att.size || 0) / 1e6).toFixed(1);
    console.log(`Audio from ${msg.author.username} — ${fname} (${sizeMB} MB)`);

    let tmpPath;
    let ownsTmpPath = false;
    try {
      if ((att.size || 0) > MAX_ATTACHMENT_BYTES) {
        throw new Error(
          `Файл больше лимита загрузки ${formatBytes(MAX_ATTACHMENT_BYTES)}`,
        );
      }
      const taskId = randomBytes(4).toString("hex");
      tmpPath = path.join(SHARED_DIR, `${taskId}_${fname}`);
      await downloadAttachment(att.url, tmpPath);
      ownsTmpPath = true;

      const modelBtns = new ActionRowBuilder().addComponents(
        ...Array.from(MODELS, ([key, model], index) =>
          new ButtonBuilder()
            .setCustomId(`${key}:${taskId}`)
            .setLabel(model.label)
            .setStyle(index === 0 ? ButtonStyle.Primary : ButtonStyle.Secondary)
        )
      );
      const cancelBtn = new ActionRowBuilder().addComponents(
        new ButtonBuilder().setCustomId(`x:${taskId}`).setLabel("Отмена").setStyle(ButtonStyle.Danger),
      );

      await msg.reply({ content: "Выберите модель:", components: [modelBtns, cancelBtn] });

      const expiryTimer = setTimeout(() => {
        const task = pendingTasks.get(taskId);
        if (task?.status !== "pending") return;
        safeUnlink(task.filePath);
        pendingTasks.delete(taskId);
        console.log(`Expired pending model choice: ${task.filename}`);
      }, PENDING_TTL_MS);

      pendingTasks.set(taskId, {
        channelId: msg.channel.id,
        replyToId: msg.id,
        requesterId: msg.author.id,
        filename: fname,
        filePath: tmpPath,
        status: "pending",
        expiryTimer,
      });
      tmpPath = null;
      ownsTmpPath = false;
    } catch (err) {
      if (tmpPath && ownsTmpPath) safeUnlink(tmpPath);
      console.error(`Failed to download ${fname}:`, err);
      await msg.reply(`Ошибка загрузки \`${fname}\`: ${err.message}`);
    }
  }
});

// ── Interaction handler (buttons) ────────────────────────────

client.on("interactionCreate", async (interaction) => {
  if (!interaction.isButton()) return;

  const customId = interaction.customId;
  const [key, taskId] = customId.split(":");
  const task = pendingTasks.get(taskId);

  if (!task) {
    await interaction.reply({ content: "Запрос устарел", ephemeral: true });
    return;
  }
  if (interaction.user.id !== task.requesterId) {
    await interaction.reply({
      content: "Эту транскрипцию может управлять только отправитель файла",
      ephemeral: true,
    });
    return;
  }

  if (key === "x") {
    clearTimeout(task.expiryTimer);
    if (task.status === "pending") {
      safeUnlink(task.filePath);
      pendingTasks.delete(taskId);
      console.log(`Cancelled before transcription: ${task.filename}`);
    } else {
      try {
        const response = await fetch(`${TRANSCRIBER_URL}/cancel`, {
          method: "POST",
          headers: INTERNAL_JSON_HEADERS,
          body: JSON.stringify({ task_id: taskId }),
        });
        if (!response.ok) {
          throw new Error(`Transcriber returned HTTP ${response.status}`);
        }
      } catch (error) {
        await interaction.reply({
          content: `Не удалось отменить задачу: ${error.message}`,
          ephemeral: true,
        });
        return;
      }
      pendingTasks.delete(taskId);
      console.log(`Cancelled during transcription: ${taskId}`);
    }
    await interaction.update({ content: "Отменено", components: [] });
    return;
  }

  const selectedModel = MODELS.get(key);
  if (selectedModel) {
    clearTimeout(task.expiryTimer);
    const modelName = selectedModel.id;
    task.status = "transcribing";
    task.model = modelName;

    console.log(`Model ${modelName} chosen for ${task.filename} by ${interaction.user.username}`);

    const cancelBtn = new ActionRowBuilder().addComponents(
      new ButtonBuilder().setCustomId(`x:${taskId}`).setLabel("Отмена").setStyle(ButtonStyle.Danger),
    );

    await interaction.update({
      content: `Транскрибирую... (${modelName})`,
      components: [cancelBtn],
    });

    task.statusMessageId = interaction.message.id;

    try {
      const response = await fetch(`${TRANSCRIBER_URL}/transcribe`, {
        method: "POST",
        headers: INTERNAL_JSON_HEADERS,
        body: JSON.stringify({
          file_path: task.filePath,
          model: key,
          task_id: taskId,
          original_name: task.filename,
        }),
      });
      if (!response.ok) {
        throw new Error(`Transcriber returned HTTP ${response.status}`);
      }
    } catch (err) {
      console.error(`Failed to enqueue transcription: ${err.message}`);
      safeUnlink(task.filePath);
      pendingTasks.delete(taskId);
      const ch = await client.channels.fetch(task.channelId);
      const statusMsg = await ch.messages.fetch(task.statusMessageId);
      await statusMsg.edit({ content: `Ошибка: ${err.message}`, components: [] });
    }
  }
});

// ── Transcription callback from Python ───────────────────────

async function handleCallback(req, res) {
  if (!hasValidInternalAuthorization(req)) {
    return res.status(401).json({ ok: false, reason: "unauthorized" });
  }

  const { task_id, text, error } = req.body;
  const task = pendingTasks.get(task_id);

  if (!task) {
    return res.json({ ok: false, reason: "unknown task" });
  }

  pendingTasks.delete(task_id);

  try {
    const ch = await client.channels.fetch(task.channelId);
    const statusMsg = await ch.messages.fetch(task.statusMessageId);
    const statusText = error
      ? `Ошибка (${task.model || "?"})`
      : `Готово (${task.model || "?"})`;
    await statusMsg.edit({ content: statusText, components: [] });
  } catch {}

  try {
    const ch = await client.channels.fetch(task.channelId);

    if (error) {
      console.error(`Transcription error for ${task.filename}: ${error}`);
      await ch.send({
        content: `Ошибка транскрибации \`${task.filename}\`:\n\`\`\`\n${error.slice(0, 1500)}\n\`\`\``,
        reply: { messageReference: task.replyToId },
      });
    } else {
      const txtName = task.filename.includes(".")
        ? task.filename.replace(/\.[^.]+$/, ".txt")
        : task.filename + ".txt";

      const file = new AttachmentBuilder(Buffer.from(text, "utf-8"), { name: txtName });
      await ch.send({
        files: [file],
        reply: { messageReference: task.replyToId },
      });
      console.log(`Sent result for ${task.filename}`);
    }
  } catch (err) {
    console.error(`Failed to send result for ${task.filename}:`, err);
  }

  res.json({ ok: true });
}

// ── Component builders ───────────────────────────────────────

function isAudio(attachment) {
  const ct = attachment.contentType || "";
  if (ct.startsWith("audio/") || ct.includes("ogg")) return true;
  const filename = safeAttachmentName(attachment.name);
  const ext = filename.includes(".")
    ? filename.split(".").pop().toLowerCase()
    : "";
  return AUDIO_EXTENSIONS.has(ext);
}

function safeAttachmentName(value) {
  const raw = typeof value === "string" ? value : "audio";
  const basename = path.posix.basename(raw.replaceAll("\\", "/"));
  const cleaned = basename
    .normalize("NFC")
    .replace(/[\p{Cc}\p{Cf}]/gu, "_")
    .trim();
  const fallback = !cleaned || cleaned === "." || cleaned === ".."
    ? "audio"
    : cleaned;

  const maxBytes = 180;
  if (Buffer.byteLength(fallback) <= maxBytes) return fallback;
  const extension = path.extname(fallback);
  const safeExtension = truncateUTF8(extension, 32);
  const stem = extension ? fallback.slice(0, -extension.length) : fallback;
  return truncateUTF8(stem, maxBytes - Buffer.byteLength(safeExtension)) + safeExtension;
}

function truncateUTF8(value, maxBytes) {
  let result = "";
  let byteCount = 0;
  for (const character of value) {
    const characterBytes = Buffer.byteLength(character);
    if (byteCount + characterBytes > maxBytes) break;
    result += character;
    byteCount += characterBytes;
  }
  return result;
}

async function downloadAttachment(url, destination) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Discord CDN returned HTTP ${response.status}`);
  }
  if (!response.body) {
    throw new Error("Discord CDN вернул пустой ответ");
  }

  const contentLength = Number.parseInt(response.headers.get("content-length") || "", 10);
  if (Number.isFinite(contentLength) && contentLength > MAX_ATTACHMENT_BYTES) {
    throw new Error(`Файл больше лимита загрузки ${formatBytes(MAX_ATTACHMENT_BYTES)}`);
  }

  let receivedBytes = 0;
  const limiter = new Transform({
    transform(chunk, _encoding, callback) {
      receivedBytes += chunk.length;
      if (receivedBytes > MAX_ATTACHMENT_BYTES) {
        callback(new Error(
          `Файл больше лимита загрузки ${formatBytes(MAX_ATTACHMENT_BYTES)}`,
        ));
        return;
      }
      callback(null, chunk);
    },
  });

  const destinationStream = fs.createWriteStream(destination, { flags: "wx" });

  try {
    await pipeline(
      Readable.fromWeb(response.body),
      limiter,
      destinationStream,
    );
  } catch (error) {
    safeUnlink(destination);
    throw error;
  }
}

function hasValidInternalAuthorization(req) {
  const provided = Buffer.from(req.get("authorization") || "", "utf8");
  const expected = Buffer.from(`Bearer ${INTERNAL_API_TOKEN}`, "utf8");
  return provided.length === expected.length && timingSafeEqual(provided, expected);
}

function safeUnlink(filePath) {
  try {
    fs.unlinkSync(filePath);
  } catch (error) {
    if (error.code !== "ENOENT") {
      console.warn(`Failed to remove ${filePath}: ${error.message}`);
    }
  }
}

function formatBytes(bytes) {
  return `${Math.ceil(bytes / 1024 / 1024)} MB`;
}

// ── Voice recording ──────────────────────────────────────────

async function cmdRecord(msg) {
  const parts = msg.content.trim().split(/\s+/);
  if (parts.length < 2) {
    await msg.reply("Использование: `!record <voice_channel_id>`");
    return;
  }

  const vcId = parts[1].replace(/[<#>]/g, "");
  const channel = client.channels.cache.get(vcId);

  if (!channel || channel.type !== 2) {
    await msg.reply("Голосовой канал не найден");
    return;
  }
  if (!msg.guild || channel.guild.id !== msg.guild.id) {
    await msg.reply("Голосовой канал должен быть на том же сервере");
    return;
  }

  if (recording) {
    await msg.reply("Запись уже идёт. `!stop` чтобы остановить");
    return;
  }

  try {
    const connection = joinVoiceChannel({
      channelId: vcId,
      guildId: channel.guild.id,
      adapterCreator: channel.guild.voiceAdapterCreator,
      selfDeaf: false,
    });

    connection.on("stateChange", (oldState, newState) => {
      console.log(`Voice connection: ${oldState.status} -> ${newState.status}`);
    });
    connection.on("error", (err) => {
      console.error("Voice connection error:", err);
    });

    await entersState(connection, VoiceConnectionStatus.Ready, 30_000);

    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "vc_rec_"));
    const writers = new Map();
    const receiver = connection.receiver;
    const startTime = Date.now();
    const startTimeNs = process.hrtime.bigint();

    const { OpusEncoder } = require("@discordjs/opus");

    const onSpeakerStart = (userId) => {
      if (writers.has(userId)) return;

      const filePath = path.join(tmpDir, `${userId}.pcm`);
      const writeStream = fs.createWriteStream(filePath);
      const decoder = new OpusEncoder(PCM_SAMPLE_RATE, PCM_CHANNELS);
      const audioStream = receiver.subscribe(userId, {
        end: { behavior: EndBehaviorType.Manual },
      });
      const writer = {
        stream: writeStream,
        audioStream,
        framesScheduled: 0,
        writeQueue: Promise.resolve(),
        writeError: null,
      };
      writers.set(userId, writer);
      console.log(`Voice: new speaker ${userId}`);

      writeStream.on("error", (err) => {
        writer.writeError ??= err;
        console.warn(`PCM file error for ${userId}: ${err.message}`);
      });

      audioStream.on("data", (packet) => {
        try {
          const pcm = decoder.decode(packet);
          enqueueTimedPCM(writer, pcm, startTimeNs);
        } catch (err) {
          console.warn(`Skipped corrupted voice packet for ${userId}: ${err.message}`);
        }
      });

      audioStream.on("error", (err) => {
        console.warn(`Audio stream error for ${userId}: ${err.message}`);
      });
    };
    receiver.speaking.on("start", onSpeakerStart);

    recording = {
      channelId: vcId,
      guildId: channel.guild.id,
      textChannelId: msg.channel.id,
      requestMsgId: msg.id,
      writers,
      tmpDir,
      startTime,
      startTimeNs,
      connection,
      receiver,
      onSpeakerStart,
    };

    console.log(`Recording started in #${channel.name} by ${msg.author.username}`);
    await msg.reply(`Записываю канал **${channel.name}**. Напишите \`!stop\` чтобы остановить.`);
  } catch (err) {
    console.error("Failed to join voice:", err);
    await msg.reply(`Не удалось подключиться: ${err.message}`);
  }
}

async function cmdStop(msg) {
  if (!recording) {
    await msg.reply("Нет активной записи");
    return;
  }

  const rec = recording;
  recording = null;

  rec.receiver.speaking.off("start", rec.onSpeakerStart);
  for (const writer of rec.writers.values()) writer.audioStream.destroy();
  rec.connection.destroy();

  const duration = ((Date.now() - rec.startTime) / 1000).toFixed(1);
  console.log(`Recording stopped after ${duration}s, mixing...`);

  const statusMsg = await msg.reply("Обрабатываю запись...");

  try {
    await finishWriterStates(rec.writers);
    const result = mixToMp3(rec.tmpDir);

    const guild = client.guilds.cache.get(rec.guildId);
    const maxUpload = guild?.premiumTier
      ? [25, 25, 50, 100][guild.premiumTier] * 1024 * 1024
      : 25 * 1024 * 1024;

    if (result.size <= maxUpload) {
      const file = new AttachmentBuilder(result.path, { name: result.name });
      await msg.channel.send({ files: [file], reply: { messageReference: msg.id } });
      await statusMsg.edit(`Запись готова: ${result.name} (${(result.size / 1e6).toFixed(1)} MB)`);
      console.log(`Recording uploaded: ${result.name}`);
    } else {
      await fallbackToTelegram(result, statusMsg, msg);
    }

    safeUnlink(result.path);
  } catch (err) {
    console.error("Failed to process recording:", err);
    await statusMsg.edit(`Ошибка обработки записи: ${err.message}`);
  } finally {
    fs.rmSync(rec.tmpDir, { recursive: true, force: true });
  }
}

function enqueueTimedPCM(writer, pcm, recordingStartNs) {
  const completeBytes = pcm.length - (pcm.length % PCM_BYTES_PER_FRAME);
  if (completeBytes === 0 || writer.writeError) return;

  const packet = completeBytes === pcm.length ? pcm : pcm.subarray(0, completeBytes);
  const packetFrames = completeBytes / PCM_BYTES_PER_FRAME;
  const elapsedNs = process.hrtime.bigint() - recordingStartNs;
  const timelineEndFrame = Number(
    elapsedNs * BigInt(PCM_SAMPLE_RATE) / 1_000_000_000n,
  );
  const targetStartFrame = Math.max(0, timelineEndFrame - packetFrames);
  const rawGapFrames = targetStartFrame - writer.framesScheduled;
  const silenceFrames = rawGapFrames > PCM_TIMELINE_TOLERANCE_FRAMES
    ? rawGapFrames
    : 0;

  writer.framesScheduled += silenceFrames + packetFrames;
  writer.writeQueue = writer.writeQueue
    .then(async () => {
      if (writer.writeError) return;
      await writeSilence(writer.stream, silenceFrames);
      await writeBuffer(writer.stream, packet);
    })
    .catch((error) => {
      writer.writeError ??= error;
    });
}

async function writeSilence(stream, frameCount) {
  let remainingFrames = frameCount;
  const framesPerChunk = SILENCE_CHUNK.length / PCM_BYTES_PER_FRAME;
  while (remainingFrames > 0) {
    const chunkFrames = Math.min(remainingFrames, framesPerChunk);
    const bytes = chunkFrames * PCM_BYTES_PER_FRAME;
    await writeBuffer(stream, SILENCE_CHUNK.subarray(0, bytes));
    remainingFrames -= chunkFrames;
  }
}

async function writeBuffer(stream, buffer) {
  if (buffer.length === 0) return;
  if (stream.write(buffer)) return;

  await new Promise((resolve, reject) => {
    const cleanup = () => {
      stream.off("drain", onDrain);
      stream.off("error", onError);
    };
    const onDrain = () => {
      cleanup();
      resolve();
    };
    const onError = (error) => {
      cleanup();
      reject(error);
    };
    stream.once("drain", onDrain);
    stream.once("error", onError);
  });
}

async function finishWriterStates(writers) {
  const failures = [];
  await Promise.all(Array.from(writers, async ([userId, writer]) => {
    await writer.writeQueue;
    const completion = finished(writer.stream);
    writer.stream.end();
    try {
      await completion;
      if (writer.writeError) throw writer.writeError;
    } catch (error) {
      failures.push(`${userId}: ${error.message}`);
    }
  }));
  if (failures.length > 0) {
    throw new Error(`Не удалось завершить PCM-дорожки: ${failures.join("; ")}`);
  }
}

function mixToMp3(tmpDir) {
  const pcmFiles = fs
    .readdirSync(tmpDir)
    .filter((f) => f.endsWith(".pcm"))
    .map((f) => path.join(tmpDir, f));

  if (pcmFiles.length === 0) throw new Error("No audio recorded");

  const ts = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 16);
  const outputName = `recording_${ts}.mp3`;
  const outputPath = path.join(SHARED_DIR, outputName);

  if (pcmFiles.length === 1) {
    execSync(
      `ffmpeg -y -f s16le -ar 48000 -ac 2 -i "${pcmFiles[0]}" -codec:a libmp3lame -b:a 128k "${outputPath}"`,
      { stdio: "pipe" }
    );
  } else {
    const inputs = pcmFiles
      .map((f) => `-f s16le -ar 48000 -ac 2 -i "${f}"`)
      .join(" ");
    execSync(
      `ffmpeg -y ${inputs} -filter_complex "amix=inputs=${pcmFiles.length}:duration=longest" -codec:a libmp3lame -b:a 128k "${outputPath}"`,
      { stdio: "pipe" }
    );
  }

  const stats = fs.statSync(outputPath);
  console.log(`Mixed ${pcmFiles.length} users to ${outputName} (${(stats.size / 1e6).toFixed(1)} MB)`);
  return { path: outputPath, name: outputName, size: stats.size };
}

async function fallbackToTelegram(result, statusMsg, originalMsg) {
  if (TELEGRAM_FALLBACK_CHATS.length === 0) {
    await statusMsg.edit("Файл слишком большой для Discord, а Telegram fallback не настроен");
    return;
  }

  await statusMsg.edit("Файл слишком большой, отправлю в Телеграм...");

  let sent = false;
  for (const chatId of TELEGRAM_FALLBACK_CHATS) {
    try {
      const response = await fetch(`${TRANSCRIBER_URL}/send-telegram`, {
        method: "POST",
        headers: INTERNAL_JSON_HEADERS,
        body: JSON.stringify({
          chat_id: chatId,
          file_path: result.path,
          filename: result.name,
        }),
      });
      if (!response.ok) {
        throw new Error(`Transcriber returned HTTP ${response.status}`);
      }
      sent = true;
      console.log(`Recording sent to TG chat ${chatId}`);
    } catch (err) {
      console.error(`Failed to send to TG chat ${chatId}:`, err);
    }
  }

  const sizeMB = (result.size / 1e6).toFixed(1);
  await statusMsg.edit(
    sent
      ? `Запись отправлена в Телеграм (${result.name}, ${sizeMB} MB)`
      : "Не удалось отправить запись ни в Discord, ни в Telegram"
  );
}

// ── Express server (callback endpoint) ───────────────────────

const app = express();
app.use(express.json());

app.get("/health", (_, res) => res.json({ ok: true }));
app.post("/callback", handleCallback);

app.listen(PORT, () => {
  console.log(`Discord bot API listening on port ${PORT}`);
});

client.login(TOKEN);
