import { StrictMode, useEffect, useState } from "react"
import { createRoot } from "react-dom/client"
import { invoke } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import {
  Activity, ArrowUpRight, AudioLines, Check, CircleAlert, FolderOpen, FolderCog,
  HardDrive, Headphones, LoaderCircle, Mic, Play, RefreshCw, Square, Volume2,
} from "lucide-react"
import { Alert, AlertDescription } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Switch } from "@/components/ui/switch"
import "./index.css"

type AudioStatus = {
  elapsed: number | null
  microphone: boolean | null
  systemLevel: number
  micLevel: number
  outputName: string
  inputName: string
  warning: string | null
}

type Recording = { name: string; duration: number; bytes: number }
type Library = { directory: string; recordings: Recording[] }
type Phase = "starting" | "saving" | null
type Notice = { text: string; error: boolean }

const shape = [10, 16, 24, 18, 34, 46, 22, 56, 86, 50, 32, 67, 96, 66, 38, 72, 110, 83, 50, 33, 65, 46, 26, 40, 27, 17, 23, 14, 9]
const sizeFormat = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 1 })

function time(seconds: number) {
  const value = Math.floor(Math.max(0, seconds))
  return [Math.floor(value / 3600), Math.floor(value / 60) % 60, value % 60]
    .map(part => String(part).padStart(2, "0")).join(":")
}

function meter(level: number) {
  return level > 0 ? Math.max(0, Math.min(1, (20 * Math.log10(level) + 54) / 54)) : 0
}

function Source({ label, device, level, microphone, onToggle, disabled }: {
  label: string
  device: string
  level: number
  microphone?: boolean
  onToggle?: (enabled: boolean) => void
  disabled?: boolean
}) {
  const Icon = onToggle ? Mic : Volume2
  const enabled = microphone !== false
  return (
    <Card className="source-card">
      <div className="source-head">
        <span className="source-icon"><Icon size={17} strokeWidth={1.9} /></span>
        <div className="source-text">
          <div className="source-label">{label}</div>
          <div className="source-device" title={device}>{enabled ? device : "已关闭麦克风"}</div>
        </div>
        {onToggle
          ? <Switch checked={enabled} onCheckedChange={onToggle} disabled={disabled} aria-label="采集麦克风" />
          : <Badge className="source-badge" variant="secondary">始终录制</Badge>}
      </div>
      <div className="meter" aria-hidden="true">
        {Array.from({ length: 24 }, (_, i) => <i key={i} data-on={enabled && meter(level) * 24 > i} />)}
      </div>
    </Card>
  )
}

function App() {
  const [audio, setAudio] = useState<AudioStatus | null>(null)
  const [mic, setMic] = useState(true)
  const [phase, setPhase] = useState<Phase>(null)
  const [notice, setNotice] = useState<Notice | null>(null)
  const [library, setLibrary] = useState<Library | null>(null)
  const recordings = library?.recordings
  const [choosingDirectory, setChoosingDirectory] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const active = audio?.elapsed != null

  function report(error: unknown) {
    setNotice({ text: String(error), error: true })
  }

  async function refresh() {
    setRefreshing(true)
    try {
      setLibrary(await invoke<Library>("recording_list"))
    } catch (error) {
      report(error)
    } finally {
      setRefreshing(false)
    }
  }

  useEffect(() => {
    void refresh()
    const subscription = listen("recording-close-blocked", () => {
      setNotice({ text: "请先停止录音并等待文件保存，然后再退出。", error: false })
    })
    return () => { void subscription.then(unlisten => unlisten()).catch(() => {}) }
  }, [])

  useEffect(() => {
    if (phase) return
    let disposed = false
    let timer: number
    async function read() {
      try {
        const status = await invoke<AudioStatus>("recording_status")
        if (!disposed) setAudio(status)
      } catch (error) {
        if (!disposed) report(error)
      }
      if (!disposed) timer = window.setTimeout(read, active ? 160 : 1800)
    }
    void read()
    return () => { disposed = true; window.clearTimeout(timer) }
  }, [active, phase])

  async function record() {
    setNotice(null)
    setPhase(active ? "saving" : "starting")
    try {
      if (active) {
        const warning = await invoke<string | null>("recording_stop")
        setAudio(previous => previous && { ...previous, elapsed: null, microphone: null, systemLevel: 0, micLevel: 0, warning: null })
        setNotice({ text: warning ?? "录音已保存到本机。", error: !!warning })
        await refresh()
      } else {
        setAudio(await invoke<AudioStatus>("recording_start", { microphone: mic }))
      }
    } catch (error) {
      report(error)
    } finally {
      setPhase(null)
    }
  }

  async function chooseDirectory() {
    setChoosingDirectory(true)
    try {
      if (await invoke<boolean>("recording_choose_directory")) {
        setNotice(null)
        setLibrary(null)
        await refresh()
      }
    } catch (error) {
      report(error)
    } finally {
      setChoosingDirectory(false)
    }
  }

  async function open(name: string | null = null, reveal = false) {
    try {
      await invoke("recording_open", { name, reveal })
    } catch (error) {
      report(error)
    }
  }

  const systemLevel = phase ? 0 : audio?.systemLevel ?? 0
  const micLevel = phase ? 0 : audio?.micLevel ?? 0
  const wave = meter(Math.max(systemLevel, micLevel))
  const stateLabel = phase === "saving" ? "正在保存" : phase === "starting" ? "正在准备" : active ? "正在录音" : "准备就绪"
  const warning = phase ? null : audio?.warning

  return (
    <div className="shell">
      <header className="app-header">
        <div className="wordmark">
          <span className="brand-icon"><AudioLines size={23} strokeWidth={2.2} /></span>
          <div><span className="brand-name">bicord</span><span className="brand-subtitle">会议录音</span></div>
        </div>
        <Badge className="local-badge" variant="outline"><HardDrive />本机保存</Badge>
      </header>

      <main>
        <section className="console" aria-label="录音控制">
          <div className="console-grid" aria-hidden="true" />
          <div className="console-content">
            <div className="console-meta">
              <span className="eyebrow"><Activity size={15} /> 录音台</span>
              <span role="status" className="console-status" data-recording={active && !phase}><i />{stateLabel}</span>
            </div>
            <div className="counter">{time(audio?.elapsed ?? 0)}</div>
            <p className="console-copy">{active ? "录音会跟随当前音频设备。" : "录下会议里听到的，也录下你说的。"}</p>
            <Button className="record-button" size="lg" onClick={record} disabled={!!phase || choosingDirectory}>
              {phase
                ? <LoaderCircle className="animate-spin" />
                : active ? <Square fill="currentColor" className="size-3!" /> : <span className="record-dot" />}
              {phase === "saving" ? "正在保存…" : phase === "starting" ? "正在启动…" : active ? "停止并保存" : "开始录音"}
            </Button>
          </div>
          <div className="wave" data-active={active && !phase} aria-hidden="true">
            {shape.map((height, i) => (
              <span key={i} style={{ height: active ? 4 + height * wave : height * 0.88 }} />
            ))}
          </div>
        </section>

        {(notice || warning) && (
          <Alert className="notice" variant={notice?.error || warning ? "destructive" : "default"}>
            {notice?.error || warning ? <CircleAlert /> : <Check />}
            <AlertDescription>{warning ?? notice?.text}</AlertDescription>
            <Button size="icon-xs" variant="ghost" className="notice-close" disabled={!notice} aria-label="关闭提示" onClick={() => setNotice(null)}>×</Button>
          </Alert>
        )}

        <section className="section" aria-labelledby="devices-title">
          <div className="section-head">
            <h2 id="devices-title">音频来源</h2>
            <span className="section-meta"><Headphones size={14} />跟随 macOS 当前设备</span>
          </div>
          <div className="sources">
            <Source label="系统声音" device={audio?.outputName ?? "正在检测…"} level={systemLevel} />
            <Source label="麦克风" device={audio?.inputName ?? "正在检测…"} level={micLevel}
              microphone={audio?.microphone ?? mic} onToggle={setMic} disabled={active || !!phase} />
          </div>
        </section>

        <section className="section history" aria-labelledby="recordings-title">
          <div className="section-head">
            <h2 id="recordings-title">录音文件 {recordings && <span className="recording-count">{recordings.length}</span>}</h2>
            <div className="history-actions">
              <Button size="icon-sm" variant="ghost" disabled={refreshing || choosingDirectory} onClick={refresh} aria-label="刷新录音列表" title="刷新录音列表">
                <RefreshCw className={refreshing ? "animate-spin" : ""} />
              </Button>
              <Button size="sm" variant="outline" disabled={choosingDirectory} onClick={() => open()}><FolderOpen />打开文件夹</Button>
              <Button size="sm" variant="outline" disabled={active || !!phase || choosingDirectory || refreshing}
                onClick={chooseDirectory}><FolderCog />更改目录</Button>
            </div>
          </div>
          <Card className="history-card">
            {recordings?.length ? (
              <ul>
                {recordings.map(recording => (
                  <li className="recording" key={recording.name}>
                    <span className="file-icon"><AudioLines size={18} /></span>
                    <div className="file-text">
                      <div className="file-name" title={recording.name}>{recording.name.replace(/(\d{2})\.(\d{2})\.(\d{2})\.\d{3}\.m4a$/, "$1:$2:$3")}</div>
                      <div className="file-details">
                        M4A · {time(recording.duration)} · {sizeFormat.format(recording.bytes / 1024 ** 2)} MB
                      </div>
                    </div>
                    <Button size="sm" variant="ghost" aria-label={`播放 ${recording.name}`} onClick={() => open(recording.name)}><Play />播放</Button>
                    <Button size="icon-sm" variant="ghost" title="在 Finder 中显示" aria-label={`在 Finder 中显示 ${recording.name}`}
                      onClick={() => open(recording.name, true)}><ArrowUpRight /></Button>
                  </li>
                ))}
              </ul>
            ) : (
              <div className="empty">
                <span className="file-icon"><AudioLines size={18} /></span>
                <div>
                  <p>{refreshing ? "正在读取录音…" : recordings ? "还没有录音" : "录音列表暂不可用"}</p>
                  <p>{recordings ? "停止录音后，M4A 文件会出现在这里。" : "可以刷新列表或打开录音文件夹。"}</p>
                </div>
              </div>
            )}
          </Card>
        </section>
      </main>

      <footer><span>bicord · macOS</span><span className="save-directory" title={library?.directory}>{library?.directory}</span></footer>
    </div>
  )
}

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>)
