import { StrictMode, useEffect, useState } from "react"
import { createRoot } from "react-dom/client"
import { invoke } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import {
  ArrowUpRight, AudioLines, Check, Circle, CircleAlert, FolderOpen, FolderCog,
  HardDrive, Headphones, LoaderCircle, Mic, Play, RefreshCw, Square, Volume2, type LucideIcon,
} from "lucide-react"
import { Alert, AlertDescription } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardAction, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card"
import { Switch } from "@/components/ui/switch"
import bicordIcon from "../src-tauri/icons/icon.svg?no-inline"
import "./index.css"

type AudioStatus = {
  elapsed: number | null
  systemAudio: boolean | null
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

const sizeFormat = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 1 })

function time(seconds: number) {
  const value = Math.floor(Math.max(0, seconds))
  return [Math.floor(value / 3600), Math.floor(value / 60) % 60, value % 60]
    .map(part => String(part).padStart(2, "0")).join(":")
}

function meter(level: number) {
  return level > 0 ? Math.max(0, Math.min(1, (20 * Math.log10(level) + 54) / 54)) : 0
}

function Source({ icon: Icon, label, device, level, enabled, onToggle, disabled }: {
  icon: LucideIcon
  label: string
  device: string
  level: number
  enabled: boolean
  onToggle: (enabled: boolean) => void
  disabled: boolean
}) {
  const activeBars = enabled ? meter(level) * 24 : 0

  return (
    <div className="space-y-2.5 py-3 first:pt-0 last:pb-0">
      <div className="flex items-center gap-3">
        <Icon className="size-4 shrink-0 text-muted-foreground" />
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium">{label}</p>
          <p className="truncate text-xs text-muted-foreground" title={enabled ? device : undefined}>
            {enabled ? device : "已关闭"}
          </p>
        </div>
        <Switch checked={enabled} onCheckedChange={onToggle} disabled={disabled} aria-label={`采集${label}`} />
      </div>
      <div className="grid grid-cols-24 gap-1" aria-hidden="true">
        {Array.from({ length: 24 }, (_, i) => (
          <span key={i} className={i < activeBars ? "h-1.5 rounded-full bg-primary" : "h-1.5 rounded-full bg-muted"} />
        ))}
      </div>
    </div>
  )
}

function App() {
  const [audio, setAudio] = useState<AudioStatus | null>(null)
  const [systemAudio, setSystemAudio] = useState(true)
  const [mic, setMic] = useState(true)
  const [phase, setPhase] = useState<Phase>(null)
  const [notice, setNotice] = useState<Notice | null>(null)
  const [library, setLibrary] = useState<Library | null>(null)
  const recordings = library?.recordings
  const [choosingDirectory, setChoosingDirectory] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const active = audio?.elapsed != null
  const noSources = !systemAudio && !mic

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
        setAudio(previous => previous && { ...previous, elapsed: null, systemAudio: null, microphone: null, systemLevel: 0, micLevel: 0, warning: null })
        setNotice({ text: warning ?? "录音已保存到本机。", error: !!warning })
        await refresh()
      } else {
        setAudio(await invoke<AudioStatus>("recording_start", { systemAudio, microphone: mic }))
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
  const stateLabel = phase === "saving" ? "正在保存" : phase === "starting" ? "正在准备" : active ? "正在录音" : "准备就绪"
  const warning = phase ? null : audio?.warning

  return (
    <div className="flex flex-col gap-4 p-4">
      <header className="flex items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <img src={bicordIcon} alt="" className="size-11 shrink-0" />
          <div>
            <h1 className="text-xl leading-tight font-semibold tracking-tight">Bicord</h1>
            <p className="text-sm text-muted-foreground">系统内录 + 麦克风</p>
          </div>
        </div>
        <Badge variant="outline"><HardDrive />本机保存</Badge>
      </header>

      <main className="flex flex-col gap-4">
        <Card role="region" aria-labelledby="recorder-title" className="gap-4 py-4">
          <CardHeader className="px-4">
            <CardTitle id="recorder-title">录音台</CardTitle>
            <CardDescription>
              {active ? "录音会跟随当前音频设备。" : noSources ? "请至少开启一路音频。" : "可将两路声音同时录进一个 M4A 文件。"}
            </CardDescription>
            <CardAction>
              <Badge role="status" variant={active && !phase ? "destructive" : "secondary"}>
                {stateLabel}
              </Badge>
            </CardAction>
          </CardHeader>
          <CardContent className="px-4">
            <div className="font-mono text-4xl leading-none font-semibold tracking-tight tabular-nums">
              {time(audio?.elapsed ?? 0)}
            </div>
          </CardContent>
          <CardFooter className="px-4">
            <Button onClick={record} disabled={!!phase || choosingDirectory || (!active && noSources)}>
              {phase
                ? <LoaderCircle className="motion-safe:animate-spin" />
                : active ? <Square fill="currentColor" /> : <Circle fill="currentColor" />}
              {phase === "saving" ? "正在保存…" : phase === "starting" ? "正在启动…" : active ? "停止并保存" : "开始录音"}
            </Button>
          </CardFooter>
        </Card>

        {(notice || warning) && (
          <Alert className="pr-12" variant={notice?.error || warning ? "destructive" : "default"}>
            {notice?.error || warning ? <CircleAlert /> : <Check />}
            <AlertDescription className="whitespace-pre-wrap wrap-anywhere">{warning ?? notice?.text}</AlertDescription>
            {notice && (
              <Button size="icon-xs" variant="ghost" className="absolute top-2 right-2" aria-label="关闭提示" onClick={() => setNotice(null)}>×</Button>
            )}
          </Alert>
        )}

        <Card role="region" aria-labelledby="devices-title" className="gap-3 py-4">
          <CardHeader className="px-4">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h2 id="devices-title" className="text-base font-semibold">音频来源</h2>
              <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
                <Headphones className="size-4" />跟随 macOS 当前设备
              </span>
            </div>
          </CardHeader>
          <CardContent className="divide-y px-4">
            <Source icon={Volume2} label="系统声音" device={audio?.outputName ?? "正在检测…"} level={systemLevel}
              enabled={audio?.systemAudio ?? systemAudio} onToggle={setSystemAudio} disabled={active || !!phase} />
            <Source icon={Mic} label="麦克风" device={audio?.inputName ?? "正在检测…"} level={micLevel}
              enabled={audio?.microphone ?? mic} onToggle={setMic} disabled={active || !!phase} />
          </CardContent>
        </Card>

        <section className="space-y-3" aria-labelledby="recordings-title">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 id="recordings-title" className="flex items-center gap-2 text-base font-semibold">
              录音文件 {recordings && <Badge variant="secondary">{recordings.length}</Badge>}
            </h2>
            <div className="flex flex-wrap items-center gap-2">
              <Button size="icon-sm" variant="ghost" disabled={refreshing || choosingDirectory} onClick={refresh} aria-label="刷新录音列表" title="刷新录音列表">
                <RefreshCw className={refreshing ? "motion-safe:animate-spin" : ""} />
              </Button>
              <Button size="sm" variant="outline" disabled={choosingDirectory} onClick={() => open()}><FolderOpen />打开文件夹</Button>
              <Button size="sm" variant="outline" disabled={active || !!phase || choosingDirectory || refreshing}
                onClick={chooseDirectory}><FolderCog />更改目录</Button>
            </div>
          </div>
          <Card className="py-0">
            {recordings?.length ? (
              <ul className="divide-y">
                {recordings.map(recording => (
                  <li className="flex items-center gap-3 px-4 py-3" key={recording.name}>
                    <AudioLines className="size-5 shrink-0 text-muted-foreground" />
                    <div className="min-w-0 flex-1">
                      <div className="truncate text-sm font-medium" title={recording.name}>{recording.name.replace(/(\d{2})\.(\d{2})\.(\d{2})\.\d{3}\.m4a$/, "$1:$2:$3")}</div>
                      <div className="text-xs text-muted-foreground">
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
              <CardContent className="flex items-center gap-3 py-4">
                <AudioLines className="size-5 shrink-0 text-muted-foreground" />
                <div>
                  <p className="text-sm font-medium">{refreshing ? "正在读取录音…" : recordings ? "还没有录音" : "录音列表暂不可用"}</p>
                  <p className="text-xs text-muted-foreground">{recordings ? "停止录音后，M4A 文件会出现在这里。" : "可以刷新列表或打开录音文件夹。"}</p>
                </div>
              </CardContent>
            )}
          </Card>
        </section>
      </main>

      <footer className="flex justify-between gap-4 text-xs text-muted-foreground">
        <span className="shrink-0">Bicord · macOS</span>
        <span className="truncate" title={library?.directory}>{library?.directory}</span>
      </footer>
    </div>
  )
}

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>)
