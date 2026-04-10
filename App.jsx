/**
 * Air Cello — Phase 1
 * 传感器可视化 + 静止检测
 *
 * 模块：
 *   - DeviceMotion 采集（60Hz 目标）
 *   - 6 通道滚动波形（Canvas）
 *   - 手机姿态角推算（accelerationIncludingGravity）
 *   - 静止检测器（能量 + 姿态角变化）
 *   - 调试面板（参数滑块 + 事件日志）
 */

import { useEffect, useRef, useState, useCallback } from 'react'

// ─────────────────────────────────────────────
// 常量
// ─────────────────────────────────────────────

const BUFFER_SIZE = 360          // 约 6 秒 @ 60Hz
const TARGET_HZ   = 60
const LOG_MAX     = 80

const CHANNELS = [
  { key: 'accX',  label: 'Acc X',  color: '#ff6b81', unit: 'm/s²' },
  { key: 'accY',  label: 'Acc Y',  color: '#ff9f43', unit: 'm/s²' },
  { key: 'accZ',  label: 'Acc Z',  color: '#ffd32a', unit: 'm/s²' },
  { key: 'rotA',  label: 'Rot α',  color: '#0be881', unit: '°/s'  },
  { key: 'rotB',  label: 'Rot β',  color: '#00d2d3', unit: '°/s'  },
  { key: 'rotG',  label: 'Rot γ',  color: '#a29bfe', unit: '°/s'  },
]

const DEFAULT_PARAMS = {
  orientationChangeThreshold: 45,   // 姿态角变化阈值（°）
  stillnessEnergyFloor:       0.08, // 综合能量低于此值视为极低能量（待校准）
  stillnessDuration:          3000, // 持续多久判静止（ms）
  accScale:                   2,    // 加速度通道显示缩放
  rotScale:                   0.04, // 角速度通道显示缩放（°/s 通常量级大）
}

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

/** 从 accelerationIncludingGravity 推算姿态角 */
function calcOrientation(grav) {
  if (!grav) return { beta: 0, gamma: 0 }
  const { x = 0, y = 0, z = 0 } = grav
  const beta  = Math.atan2(y, Math.sqrt(x * x + z * z)) * (180 / Math.PI)
  const gamma = Math.atan2(-x, z)                        * (180 / Math.PI)
  return { beta, gamma }
}

/** 两个姿态角之间的最大差值（简单欧氏距离） */
function orientationDelta(a, b) {
  return Math.sqrt(
    Math.pow(a.beta  - b.beta,  2) +
    Math.pow(a.gamma - b.gamma, 2)
  )
}

/** 综合能量（6 通道平方和，归一化到各通道量级）：
 *  acc 单位 m/s²，rot 单位 °/s。各自归一化。 */
function calcEnergy(frame) {
  const s = 0.02   // acc 压缩系数
  const r = 0.0005 // rot 压缩系数
  return (
    frame.accX ** 2 * s + frame.accY ** 2 * s + frame.accZ ** 2 * s +
    frame.rotA ** 2 * r + frame.rotB ** 2 * r + frame.rotG ** 2 * r
  )
}

function fmtNum(n, d = 2) {
  if (n == null || isNaN(n)) return '--'
  return (n >= 0 ? ' ' : '') + n.toFixed(d)
}

function now() { return performance.now() }

// ─────────────────────────────────────────────
// 静止检测器
// ─────────────────────────────────────────────

class StillnessDetector {
  constructor(params) {
    this.params   = params
    this.state    = 'PLAYING'   // 'PLAYING' | 'STILL'
    this.lowEnergyStart = null  // 低能量开始时间
    this.playOrientation = null // 演奏基准姿态
  }

  update(frame, orientation, ts) {
    const { orientationChangeThreshold, stillnessEnergyFloor, stillnessDuration } = this.params

    // 初始化基准姿态（首次调用）
    if (!this.playOrientation) {
      this.playOrientation = { ...orientation }
    }

    const energy = calcEnergy(frame)
    const oriDelta = orientationDelta(orientation, this.playOrientation)

    // ── 路径 A：姿态突变 ──
    if (oriDelta > orientationChangeThreshold) {
      if (this.state === 'PLAYING') {
        this.state = 'STILL'
        this.lowEnergyStart = null
        return { state: 'STILL', reason: `姿态突变 Δ${oriDelta.toFixed(1)}°`, energy, oriDelta }
      }
    }

    // ── 路径 B：长时间低能量 ──
    if (energy < stillnessEnergyFloor) {
      if (this.lowEnergyStart === null) this.lowEnergyStart = ts
      const duration = ts - this.lowEnergyStart
      if (duration >= stillnessDuration && this.state === 'PLAYING') {
        this.state = 'STILL'
        return { state: 'STILL', reason: `低能量持续 ${(duration / 1000).toFixed(1)}s`, energy, oriDelta }
      }
    } else {
      this.lowEnergyStart = null
    }

    // ── 退出静止 ──
    if (this.state === 'STILL') {
      // 任一通道能量明显高于地板 且 姿态回归演奏范围
      if (energy > stillnessEnergyFloor * 3 && oriDelta < orientationChangeThreshold * 0.7) {
        this.state = 'PLAYING'
        this.playOrientation = { ...orientation }
        return { state: 'PLAYING', reason: '恢复运动', energy, oriDelta }
      }
    }

    return { state: this.state, energy, oriDelta }
  }

  reset(orientation) {
    this.state = 'PLAYING'
    this.lowEnergyStart = null
    this.playOrientation = orientation ? { ...orientation } : null
  }
}

// ─────────────────────────────────────────────
// 主应用
// ─────────────────────────────────────────────

export default function App() {
  // ── 传感器权限 & 状态 ──
  const [sensorState, setSensorState] = useState('idle') // idle | requesting | active | denied | unsupported
  const [motionState, setMotionState] = useState('PLAYING')
  const [orientation, setOrientation] = useState({ beta: 0, gamma: 0 })
  const [energy, setEnergy]           = useState(0)
  const [oriDelta, setOriDelta]       = useState(0)
  const [fps, setFps]                 = useState(0)

  // ── 参数 ──
  const [params, setParams] = useState({ ...DEFAULT_PARAMS })
  const paramsRef = useRef(params)
  useEffect(() => { paramsRef.current = params }, [params])

  // ── UI 状态 ──
  const [debugOpen, setDebugOpen]         = useState(true)
  const [channelVisible, setChannelVisible] = useState(() => CHANNELS.reduce((a, c) => ({ ...a, [c.key]: true }), {}))
  const [log, setLog]                     = useState([])
  const [lowEnergyMs, setLowEnergyMs]     = useState(0) // 低能量已持续时间

  // ── 内部 refs（不触发渲染） ──
  const bufferRef    = useRef(CHANNELS.reduce((a, c) => ({ ...a, [c.key]: new Float32Array(BUFFER_SIZE) }), {}))
  const writePtr     = useRef(0)
  const frameCount   = useRef(0)
  const fpsTimer     = useRef(null)
  const detectorRef  = useRef(null)
  const canvasRef    = useRef(null)
  const rafRef       = useRef(null)
  const lastOriRef   = useRef({ beta: 0, gamma: 0 })
  const lowEnergyStartRef = useRef(null)

  // ── 追加日志 ──
  const addLog = useCallback((msg, type = 'info') => {
    const ts = new Date().toLocaleTimeString('zh-CN', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' })
    setLog(prev => [{ ts, msg, type, id: Date.now() + Math.random() }, ...prev].slice(0, LOG_MAX))
  }, [])

  // ── 重置基准姿态 ──
  const resetBaseline = useCallback(() => {
    if (detectorRef.current) {
      detectorRef.current.reset(lastOriRef.current)
      addLog('基准姿态已重置', 'success')
    }
  }, [addLog])

  // ── 请求传感器权限 & 启动 ──
  const startSensor = useCallback(async () => {
    if (!window.DeviceMotionEvent) {
      setSensorState('unsupported')
      addLog('浏览器不支持 DeviceMotion API', 'error')
      return
    }

    setSensorState('requesting')

    // iOS 13+ 需要显式请求权限
    if (typeof DeviceMotionEvent.requestPermission === 'function') {
      try {
        const perm = await DeviceMotionEvent.requestPermission()
        if (perm !== 'granted') {
          setSensorState('denied')
          addLog('传感器权限被拒绝', 'error')
          return
        }
      } catch (e) {
        setSensorState('denied')
        addLog(`权限请求失败：${e.message}`, 'error')
        return
      }
    }

    setSensorState('active')
    addLog('传感器已启动 ✓', 'success')
  }, [addLog])

  // ── 挂载传感器监听 ──
  useEffect(() => {
    if (sensorState !== 'active') return

    detectorRef.current = new StillnessDetector(paramsRef.current)

    let lastFpsTick = now()
    let frameCountLocal = 0

    const onMotion = (evt) => {
      const t = now()
      const acc = evt.acceleration             || {}
      const rot = evt.rotationRate             || {}
      const grav = evt.accelerationIncludingGravity || {}

      const frame = {
        accX: acc.x  ?? 0,
        accY: acc.y  ?? 0,
        accZ: acc.z  ?? 0,
        rotA: rot.alpha ?? 0,
        rotB: rot.beta  ?? 0,
        rotG: rot.gamma ?? 0,
      }

      // 推算姿态角
      const ori = calcOrientation(grav)
      lastOriRef.current = ori

      // 写入环形缓冲区
      const ptr = writePtr.current % BUFFER_SIZE
      CHANNELS.forEach(ch => { bufferRef.current[ch.key][ptr] = frame[ch.key] })
      writePtr.current++

      // 更新静止检测器
      if (detectorRef.current) {
        detectorRef.current.params = paramsRef.current
        const result = detectorRef.current.update(frame, ori, t)

        // 低能量持续时间（用于进度条显示）
        if (result.energy < paramsRef.current.stillnessEnergyFloor) {
          if (lowEnergyStartRef.current === null) lowEnergyStartRef.current = t
          setLowEnergyMs(t - lowEnergyStartRef.current)
        } else {
          lowEnergyStartRef.current = null
          setLowEnergyMs(0)
        }

        if (result.state !== motionState) {
          setMotionState(result.state)
          setEnergy(result.energy)
          setOriDelta(result.oriDelta ?? 0)
          if (result.reason) {
            const type = result.state === 'STILL' ? 'warn' : 'success'
            addLog(`→ ${result.state}：${result.reason}`, type)
          }
        }

        setEnergy(result.energy)
        setOriDelta(result.oriDelta ?? 0)
      }

      // 更新姿态角显示（节流）
      frameCountLocal++
      if (frameCountLocal % 4 === 0) {
        setOrientation(ori)
      }

      // FPS 计算
      frameCount.current++
      if (t - lastFpsTick >= 1000) {
        setFps(Math.round(frameCount.current * 1000 / (t - lastFpsTick)))
        frameCount.current = 0
        lastFpsTick = t
      }
    }

    window.addEventListener('devicemotion', onMotion)
    return () => window.removeEventListener('devicemotion', onMotion)
  }, [sensorState, addLog]) // eslint-disable-line

  // ── Canvas 绘制循环 ──
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')

    const LANE_H = 72      // 每个通道的高度
    const LABEL_W = 58     // 左侧标签宽度
    const PAD = 4

    const draw = () => {
      rafRef.current = requestAnimationFrame(draw)

      const W = canvas.width
      const totalChannels = CHANNELS.filter(c => channelVisible[c.key]).length
      if (totalChannels === 0) {
        ctx.fillStyle = '#0a0a0f'
        ctx.fillRect(0, 0, W, canvas.height)
        return
      }

      const visibleChannels = CHANNELS.filter(c => channelVisible[c.key])
      const totalH = visibleChannels.length * LANE_H
      if (canvas.height !== totalH) {
        canvas.height = totalH
      }

      ctx.fillStyle = '#0a0a0f'
      ctx.fillRect(0, 0, W, totalH)

      const plotW = W - LABEL_W

      visibleChannels.forEach((ch, laneIdx) => {
        const y0 = laneIdx * LANE_H
        const midY = y0 + LANE_H / 2

        // 背景
        ctx.fillStyle = laneIdx % 2 === 0 ? '#0d0d14' : '#0a0a0f'
        ctx.fillRect(0, y0, W, LANE_H)

        // 分隔线
        ctx.strokeStyle = '#1e1e2e'
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(0, y0 + LANE_H - 0.5)
        ctx.lineTo(W, y0 + LANE_H - 0.5)
        ctx.stroke()

        // 中线
        ctx.strokeStyle = '#1a1a28'
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(LABEL_W, midY)
        ctx.lineTo(W, midY)
        ctx.stroke()

        // 波形
        const buf  = bufferRef.current[ch.key]
        const ptr  = writePtr.current
        const isAcc = ch.key.startsWith('acc')
        const scale = (isAcc ? paramsRef.current.accScale : paramsRef.current.rotScale)
        const halfH = LANE_H / 2 - PAD

        ctx.strokeStyle = ch.color
        ctx.lineWidth   = 1.5
        ctx.shadowBlur  = 4
        ctx.shadowColor = ch.color + '80'
        ctx.beginPath()

        for (let i = 0; i < plotW; i++) {
          const idx = (ptr - plotW + i + BUFFER_SIZE * 10) % BUFFER_SIZE
          const val = buf[idx]
          const px  = LABEL_W + i
          const py  = midY - Math.max(-halfH, Math.min(halfH, val * halfH * scale))
          if (i === 0) ctx.moveTo(px, py)
          else         ctx.lineTo(px, py)
        }
        ctx.stroke()
        ctx.shadowBlur = 0

        // 标签区
        ctx.fillStyle = '#111118'
        ctx.fillRect(0, y0, LABEL_W, LANE_H)

        // 通道色条
        ctx.fillStyle = ch.color
        ctx.fillRect(0, y0, 3, LANE_H)

        // 标签文字
        ctx.font      = 'bold 11px monospace'
        ctx.fillStyle = ch.color
        ctx.textAlign = 'left'
        ctx.fillText(ch.label, 6, y0 + 22)

        // 当前值
        const curIdx = (ptr - 1 + BUFFER_SIZE * 10) % BUFFER_SIZE
        const curVal = buf[curIdx]
        ctx.font      = '10px monospace'
        ctx.fillStyle = '#888'
        ctx.fillText(fmtNum(curVal, 1), 6, y0 + 38)

        // 单位
        ctx.font      = '9px sans-serif'
        ctx.fillStyle = '#444'
        ctx.fillText(ch.unit, 6, y0 + 52)
      })
    }

    rafRef.current = requestAnimationFrame(draw)
    return () => cancelAnimationFrame(rafRef.current)
  }, [channelVisible])

  // ── 参数变化时同步到 detector ──
  useEffect(() => {
    if (detectorRef.current) detectorRef.current.params = params
  }, [params])

  // ── helpers ──
  const setParam = (key, val) => setParams(p => ({ ...p, [key]: val }))
  const toggleChannel = (key) => setChannelVisible(v => ({ ...v, [key]: !v[key] }))

  const statusColor = motionState === 'STILL' ? '#ff4757' : '#2ed573'
  const statusBg    = motionState === 'STILL' ? '#ff475718' : '#2ed57318'

  const lowEnergyPct = Math.min(100, (lowEnergyMs / params.stillnessDuration) * 100)

  // ─────────────────────────────────────────────
  // 渲染
  // ─────────────────────────────────────────────

  return (
    <div style={S.root}>

      {/* ── 顶栏 ── */}
      <div style={S.topBar}>
        <div style={S.appTitle}>
          <span style={S.titleIcon}>🎻</span>
          <span style={S.titleText}>Air Cello</span>
          <span style={S.phaseTag}>Phase 1</span>
        </div>

        {sensorState === 'active' && (
          <div style={S.fpsTag}>{fps} Hz</div>
        )}

        {/* 状态指示灯 */}
        {sensorState === 'active' && (
          <div style={{ ...S.statusBadge, color: statusColor, background: statusBg, borderColor: statusColor + '40' }}>
            <div style={{ ...S.statusDot, background: statusColor, boxShadow: `0 0 8px ${statusColor}` }} />
            {motionState}
          </div>
        )}
      </div>

      {/* ── 权限启动区 ── */}
      {sensorState !== 'active' && (
        <div style={S.permCard}>
          {sensorState === 'idle' && (
            <>
              <div style={S.permTitle}>📱 在手机上打开</div>
              <div style={S.permDesc}>需要访问陀螺仪和加速度传感器来可视化手机运动数据</div>
              <button style={S.startBtn} onClick={startSensor}>
                启动传感器
              </button>
            </>
          )}
          {sensorState === 'requesting' && (
            <div style={S.permDesc}>⏳ 正在请求权限…</div>
          )}
          {sensorState === 'denied' && (
            <>
              <div style={S.permTitle}>🚫 权限被拒绝</div>
              <div style={S.permDesc}>请在浏览器设置中允许访问传感器，然后刷新页面</div>
            </>
          )}
          {sensorState === 'unsupported' && (
            <>
              <div style={S.permTitle}>❌ 不支持</div>
              <div style={S.permDesc}>浏览器不支持 DeviceMotion API。请在手机 Safari / Chrome 中打开，且需要 HTTPS。</div>
            </>
          )}
        </div>
      )}

      {/* ── 通道开关 ── */}
      {sensorState === 'active' && (
        <div style={S.chToggleBar}>
          {CHANNELS.map(ch => (
            <button
              key={ch.key}
              style={{
                ...S.chBtn,
                color:       channelVisible[ch.key] ? ch.color : '#333',
                borderColor: channelVisible[ch.key] ? ch.color + '60' : '#222',
                background:  channelVisible[ch.key] ? ch.color + '12' : 'transparent',
              }}
              onClick={() => toggleChannel(ch.key)}
            >
              {ch.label}
            </button>
          ))}
        </div>
      )}

      {/* ── 波形 Canvas ── */}
      {sensorState === 'active' && (
        <div style={S.canvasWrap}>
          <canvas
            ref={canvasRef}
            style={S.canvas}
            width={window.innerWidth}
            height={CHANNELS.filter(c => channelVisible[c.key]).length * 72}
          />
        </div>
      )}

      {/* ── 姿态角显示 ── */}
      {sensorState === 'active' && (
        <div style={S.orientSection}>
          <div style={S.sectionLabel}>手机姿态角</div>
          <div style={S.orientRow}>

            {/* Beta（前后倾斜）*/}
            <div style={S.orientCard}>
              <div style={S.orientLabel}>β Beta</div>
              <div style={S.orientSub}>前后倾</div>
              <div style={S.orientVal}>{fmtNum(orientation.beta, 1)}°</div>
              <OrientBar value={orientation.beta} min={-90} max={90} color="#00d2d3" />
            </div>

            {/* Gamma（左右倾斜）*/}
            <div style={S.orientCard}>
              <div style={S.orientLabel}>γ Gamma</div>
              <div style={S.orientSub}>左右倾</div>
              <div style={S.orientVal}>{fmtNum(orientation.gamma, 1)}°</div>
              <OrientBar value={orientation.gamma} min={-90} max={90} color="#a29bfe" />
            </div>

            {/* 综合能量 */}
            <div style={S.orientCard}>
              <div style={S.orientLabel}>⚡ 能量</div>
              <div style={S.orientSub}>综合 6ch</div>
              <div style={{ ...S.orientVal, color: energy < params.stillnessEnergyFloor ? '#ff4757' : '#2ed573' }}>
                {energy.toFixed(4)}
              </div>
              {/* 低能量倒计时进度条 */}
              <div style={S.energyBarBg}>
                <div style={{
                  ...S.energyBarFill,
                  width: `${lowEnergyPct}%`,
                  background: lowEnergyPct > 70 ? '#ff4757' : '#ffd32a',
                }} />
              </div>
              <div style={S.energyBarLabel}>
                {lowEnergyMs > 0
                  ? `低能量 ${(lowEnergyMs / 1000).toFixed(1)}s / ${(params.stillnessDuration / 1000).toFixed(1)}s`
                  : '能量正常'}
              </div>
            </div>

            {/* 姿态变化量 */}
            <div style={S.orientCard}>
              <div style={S.orientLabel}>△ 姿态差</div>
              <div style={S.orientSub}>vs 基准</div>
              <div style={{ ...S.orientVal, color: oriDelta > params.orientationChangeThreshold ? '#ff4757' : '#fff' }}>
                {fmtNum(oriDelta, 1)}°
              </div>
              <div style={S.orientSub}>
                阈值 {params.orientationChangeThreshold}°
                {oriDelta > params.orientationChangeThreshold && ' ⚠️'}
              </div>
            </div>

          </div>

          <button style={S.resetBtn} onClick={resetBaseline}>
            重置基准姿态
          </button>
        </div>
      )}

      {/* ── 调试面板 ── */}
      {sensorState === 'active' && (
        <div style={S.debugPanel}>
          <button style={S.debugToggle} onClick={() => setDebugOpen(o => !o)}>
            <span>⚙️ 调试面板</span>
            <span style={{ fontSize: 12, color: '#555' }}>{debugOpen ? '▲ 收起' : '▼ 展开'}</span>
          </button>

          {debugOpen && (
            <div style={S.debugBody}>

              {/* 参数滑块 */}
              <div style={S.debugSection}>
                <div style={S.debugSectionTitle}>静止检测参数</div>

                <ParamSlider
                  label="orientationChangeThreshold"
                  desc="姿态角变化阈值 (°)"
                  value={params.orientationChangeThreshold}
                  min={10} max={120} step={1}
                  onChange={v => setParam('orientationChangeThreshold', v)}
                />
                <ParamSlider
                  label="stillnessEnergyFloor"
                  desc="静止能量底线"
                  value={params.stillnessEnergyFloor}
                  min={0.001} max={0.5} step={0.001}
                  fmt={v => v.toFixed(3)}
                  onChange={v => setParam('stillnessEnergyFloor', v)}
                />
                <ParamSlider
                  label="stillnessDuration"
                  desc="低能量持续时长 (ms)"
                  value={params.stillnessDuration}
                  min={500} max={8000} step={100}
                  fmt={v => `${v}ms`}
                  onChange={v => setParam('stillnessDuration', v)}
                />
              </div>

              {/* 显示缩放 */}
              <div style={S.debugSection}>
                <div style={S.debugSectionTitle}>波形显示缩放</div>
                <ParamSlider
                  label="accScale"
                  desc="加速度通道缩放"
                  value={params.accScale}
                  min={0.1} max={10} step={0.1}
                  fmt={v => `×${v.toFixed(1)}`}
                  onChange={v => setParam('accScale', v)}
                />
                <ParamSlider
                  label="rotScale"
                  desc="角速度通道缩放"
                  value={params.rotScale}
                  min={0.001} max={0.2} step={0.001}
                  fmt={v => `×${v.toFixed(3)}`}
                  onChange={v => setParam('rotScale', v)}
                />
              </div>

              {/* 实时数值表 */}
              <div style={S.debugSection}>
                <div style={S.debugSectionTitle}>实时传感器数值</div>
                <div style={S.dataGrid}>
                  {CHANNELS.map(ch => {
                    const ptr = writePtr.current
                    const idx = (ptr - 1 + BUFFER_SIZE * 10) % BUFFER_SIZE
                    const val = bufferRef.current[ch.key][idx]
                    return (
                      <div key={ch.key} style={S.dataCell}>
                        <span style={{ color: ch.color }}>{ch.label}</span>
                        <span style={S.dataCellVal}>{fmtNum(val, 2)}</span>
                        <span style={S.dataCellUnit}>{ch.unit}</span>
                      </div>
                    )
                  })}
                </div>
              </div>

              {/* 事件日志 */}
              <div style={S.debugSection}>
                <div style={{ ...S.debugSectionTitle, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <span>事件日志</span>
                  <button style={S.clearBtn} onClick={() => setLog([])}>清空</button>
                </div>
                <div style={S.logBox}>
                  {log.length === 0 && (
                    <div style={{ color: '#333', padding: '8px 0', fontSize: 12 }}>暂无事件</div>
                  )}
                  {log.map(entry => (
                    <div key={entry.id} style={{ ...S.logEntry, color: logColor(entry.type) }}>
                      <span style={S.logTs}>{entry.ts}</span>
                      <span>{entry.msg}</span>
                    </div>
                  ))}
                </div>
              </div>

              {/* 预留区 */}
              <div style={S.debugSection}>
                <div style={S.debugSectionTitle}>预留扩展区（Phase 2+）</div>
                <div style={{ color: '#333', fontSize: 12, padding: '8px 0' }}>
                  方向反转检测、bowSignal 融合权重、zero-crossing 标记…
                </div>
              </div>

            </div>
          )}
        </div>
      )}

    </div>
  )
}

// ─────────────────────────────────────────────
// 子组件
// ─────────────────────────────────────────────

function OrientBar({ value, min, max, color }) {
  const pct = ((value - min) / (max - min)) * 100
  const clamp = Math.max(0, Math.min(100, pct))
  return (
    <div style={{ background: '#1a1a28', borderRadius: 3, height: 6, marginTop: 6, position: 'relative', overflow: 'hidden' }}>
      {/* 中心线 */}
      <div style={{ position: 'absolute', left: '50%', top: 0, width: 1, height: '100%', background: '#333' }} />
      {/* 填充 */}
      <div style={{
        position: 'absolute',
        left:   clamp >= 50 ? '50%' : `${clamp}%`,
        width:  `${Math.abs(clamp - 50)}%`,
        top: 0, bottom: 0,
        background: color,
        opacity: 0.8,
      }} />
    </div>
  )
}

function ParamSlider({ label, desc, value, min, max, step, fmt, onChange }) {
  const display = fmt ? fmt(value) : value
  return (
    <div style={S.sliderRow}>
      <div style={S.sliderMeta}>
        <code style={S.sliderKey}>{label}</code>
        <span style={S.sliderVal}>{display}</span>
      </div>
      <div style={S.sliderDesc}>{desc}</div>
      <input
        type="range"
        min={min} max={max} step={step}
        value={value}
        onChange={e => onChange(Number(e.target.value))}
        style={S.slider}
      />
    </div>
  )
}

// ─────────────────────────────────────────────
// 日志颜色
// ─────────────────────────────────────────────

function logColor(type) {
  switch (type) {
    case 'success': return '#2ed573'
    case 'warn':    return '#ffd32a'
    case 'error':   return '#ff4757'
    default:        return '#666'
  }
}

// ─────────────────────────────────────────────
// 样式（CSS-in-JS）
// ─────────────────────────────────────────────

const S = {
  root: {
    width: '100%',
    minHeight: '100vh',
    background: '#0a0a0f',
    color: '#e0e0e8',
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
    display: 'flex',
    flexDirection: 'column',
    userSelect: 'none',
    WebkitUserSelect: 'none',
  },

  // ── 顶栏 ──
  topBar: {
    display: 'flex',
    alignItems: 'center',
    gap: 10,
    padding: '12px 14px 10px',
    borderBottom: '1px solid #1a1a28',
    background: '#0d0d16',
    flexShrink: 0,
  },
  appTitle: {
    display: 'flex',
    alignItems: 'center',
    gap: 6,
    flex: 1,
  },
  titleIcon: { fontSize: 20 },
  titleText: { fontSize: 17, fontWeight: 700, letterSpacing: 0.5 },
  phaseTag: {
    fontSize: 10,
    background: '#1e1e3a',
    color: '#7c7caa',
    padding: '2px 6px',
    borderRadius: 4,
    fontWeight: 600,
    letterSpacing: 1,
  },
  fpsTag: {
    fontSize: 11,
    color: '#444',
    fontFamily: 'monospace',
    minWidth: 44,
    textAlign: 'right',
  },
  statusBadge: {
    display: 'flex',
    alignItems: 'center',
    gap: 6,
    fontSize: 12,
    fontWeight: 700,
    letterSpacing: 1,
    padding: '4px 10px',
    borderRadius: 20,
    border: '1px solid',
  },
  statusDot: {
    width: 7,
    height: 7,
    borderRadius: '50%',
    flexShrink: 0,
  },

  // ── 权限卡片 ──
  permCard: {
    flex: 1,
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 16,
    padding: 32,
    textAlign: 'center',
  },
  permTitle: {
    fontSize: 20,
    fontWeight: 700,
  },
  permDesc: {
    fontSize: 14,
    color: '#666',
    lineHeight: 1.6,
    maxWidth: 300,
  },
  startBtn: {
    marginTop: 8,
    padding: '14px 36px',
    fontSize: 16,
    fontWeight: 700,
    background: 'linear-gradient(135deg, #6c63ff, #3b3b98)',
    color: '#fff',
    border: 'none',
    borderRadius: 14,
    cursor: 'pointer',
    boxShadow: '0 4px 20px #6c63ff44',
    WebkitTapHighlightColor: 'transparent',
  },

  // ── 通道开关 ──
  chToggleBar: {
    display: 'flex',
    flexWrap: 'wrap',
    gap: 6,
    padding: '8px 12px',
    borderBottom: '1px solid #141420',
    flexShrink: 0,
  },
  chBtn: {
    fontSize: 11,
    fontWeight: 700,
    fontFamily: 'monospace',
    padding: '3px 8px',
    borderRadius: 6,
    border: '1px solid',
    cursor: 'pointer',
    WebkitTapHighlightColor: 'transparent',
    transition: 'all 0.15s',
  },

  // ── Canvas ──
  canvasWrap: {
    flexShrink: 0,
    overflow: 'hidden',
    borderBottom: '1px solid #141420',
  },
  canvas: {
    display: 'block',
    width: '100%',
    touchAction: 'none',
  },

  // ── 姿态角 ──
  orientSection: {
    padding: '12px 12px 8px',
    borderBottom: '1px solid #141420',
    flexShrink: 0,
  },
  sectionLabel: {
    fontSize: 11,
    fontWeight: 700,
    letterSpacing: 1,
    color: '#444',
    textTransform: 'uppercase',
    marginBottom: 8,
  },
  orientRow: {
    display: 'grid',
    gridTemplateColumns: 'repeat(4, 1fr)',
    gap: 8,
  },
  orientCard: {
    background: '#0e0e1c',
    borderRadius: 8,
    padding: '8px 10px',
    border: '1px solid #1a1a2e',
  },
  orientLabel: {
    fontSize: 12,
    fontWeight: 700,
    color: '#888',
    marginBottom: 2,
  },
  orientSub: {
    fontSize: 10,
    color: '#444',
    marginBottom: 4,
  },
  orientVal: {
    fontSize: 15,
    fontWeight: 700,
    fontFamily: 'monospace',
    letterSpacing: -0.5,
  },
  energyBarBg: {
    background: '#1a1a28',
    borderRadius: 3,
    height: 6,
    marginTop: 6,
    overflow: 'hidden',
  },
  energyBarFill: {
    height: '100%',
    borderRadius: 3,
    transition: 'width 0.15s, background 0.3s',
  },
  energyBarLabel: {
    fontSize: 9,
    color: '#444',
    marginTop: 3,
  },
  resetBtn: {
    marginTop: 10,
    padding: '6px 14px',
    fontSize: 12,
    background: '#1a1a2e',
    color: '#7c7caa',
    border: '1px solid #2a2a44',
    borderRadius: 8,
    cursor: 'pointer',
    WebkitTapHighlightColor: 'transparent',
  },

  // ── 调试面板 ──
  debugPanel: {
    flexShrink: 0,
    borderTop: '1px solid #141420',
  },
  debugToggle: {
    width: '100%',
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: '10px 14px',
    background: '#0d0d16',
    border: 'none',
    color: '#bbb',
    fontSize: 14,
    fontWeight: 600,
    cursor: 'pointer',
    WebkitTapHighlightColor: 'transparent',
  },
  debugBody: {
    background: '#0a0a12',
    padding: '0 0 24px',
  },
  debugSection: {
    padding: '12px 14px',
    borderBottom: '1px solid #111120',
  },
  debugSectionTitle: {
    fontSize: 11,
    fontWeight: 700,
    letterSpacing: 1,
    color: '#444',
    textTransform: 'uppercase',
    marginBottom: 10,
  },

  // ── 滑块 ──
  sliderRow: {
    marginBottom: 12,
  },
  sliderMeta: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 3,
  },
  sliderKey: {
    fontSize: 12,
    color: '#7c7caa',
    fontFamily: 'monospace',
  },
  sliderVal: {
    fontSize: 13,
    fontWeight: 700,
    fontFamily: 'monospace',
    color: '#e0e0e8',
  },
  sliderDesc: {
    fontSize: 11,
    color: '#444',
    marginBottom: 6,
  },
  slider: {
    width: '100%',
    accentColor: '#6c63ff',
    cursor: 'pointer',
  },

  // ── 实时数值表 ──
  dataGrid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(3, 1fr)',
    gap: 6,
  },
  dataCell: {
    background: '#0e0e1c',
    borderRadius: 6,
    padding: '6px 8px',
    display: 'flex',
    flexDirection: 'column',
    gap: 2,
    fontSize: 11,
    fontFamily: 'monospace',
  },
  dataCellVal: {
    fontSize: 14,
    fontWeight: 700,
    color: '#e0e0e8',
  },
  dataCellUnit: {
    fontSize: 9,
    color: '#333',
  },

  // ── 日志 ──
  logBox: {
    background: '#080810',
    borderRadius: 8,
    padding: '8px 10px',
    maxHeight: 180,
    overflowY: 'auto',
    border: '1px solid #111120',
  },
  logEntry: {
    display: 'flex',
    gap: 8,
    fontSize: 12,
    fontFamily: 'monospace',
    padding: '3px 0',
    borderBottom: '1px solid #111118',
  },
  logTs: {
    color: '#333',
    flexShrink: 0,
  },
  clearBtn: {
    fontSize: 11,
    padding: '2px 8px',
    background: '#1a1a2e',
    color: '#555',
    border: '1px solid #222',
    borderRadius: 4,
    cursor: 'pointer',
  },
}
