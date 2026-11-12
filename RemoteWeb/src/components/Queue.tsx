import { useRef, useState } from 'react'
import { GripVertical, ListX, Play, Trash2 } from 'lucide-react'
import type { RemoteQueue, RemoteTrack } from '../protocol'
import { formatTime, send, useRemote } from '../api'
import { Artwork, useSheet, usePress } from '../ui'

function target(queue: RemoteQueue, absoluteIndex: number) {
  const item = queue.items[absoluteIndex - queue.offset]
  return { index: absoluteIndex, key: item?.key ?? '', revision: queue.revision }
}

function QueueRow({
  queue,
  track,
  index,
  current,
  past,
  canDrag,
  dragging,
  onDragStart,
}: {
  queue: RemoteQueue
  track: RemoteTrack
  index: number
  current: boolean
  past: boolean
  canDrag: boolean
  dragging: boolean
  onDragStart: (event: React.PointerEvent, index: number) => void
}) {
  const openSheet = useSheet((s) => s.open)
  const press = usePress(
    () => { if (!current) send({ type: 'queue-jump', target: target(queue, index) }) },
    () => openSheet({
      title: track.title,
      subtitle: track.artist,
      artwork: track.artwork,
      actions: [
        { label: 'Play now', icon: Play, disabled: current, run: () => send({ type: 'queue-jump', target: target(queue, index) }) },
        { label: 'Remove from queue', icon: Trash2, disabled: current, run: () => send({ type: 'queue-remove', target: target(queue, index) }) },
      ],
    }),
  )
  return (
    <div className={`row ${current ? 'current' : ''} ${past ? 'dim' : ''} ${dragging ? 'dragging' : ''}`} data-queue-index={index}>
      <button type="button" className="row" style={{ border: 0, padding: 0, minHeight: 52 }} {...press} aria-label={current ? `${track.title}, playing now` : `Play ${track.title}`}>
        <Artwork src={track.artwork} kind={track.isRadio ? 'track' : 'album'} className="row-art" />
        <span className="row-text">
          <span className="row-title" style={{ display: 'block' }}>{track.title}</span>
          <span className="row-sub" style={{ display: 'block' }}>{track.artist}</span>
        </span>
        <span className="row-trail tabular">{track.durationSec > 0 ? formatTime(track.durationSec) : ''}</span>
      </button>
      {canDrag && (
        <span
          className="icon-button queue-drag"
          role="button"
          aria-label={`Move ${track.title}`}
          onPointerDown={(event) => onDragStart(event, index)}
        >
          <GripVertical size={20} />
        </span>
      )}
    </div>
  )
}

export default function Queue() {
  const queue = useRemote((s) => s.queue)
  const listRef = useRef<HTMLDivElement>(null)
  const [drag, setDrag] = useState<{ from: number; over: number } | null>(null)

  if (!queue || queue.total === 0) {
    return (
      <>
        <h1 className="page-title">Queue</h1>
        <div className="empty"><strong>The queue is empty</strong>Play something from your library to fill it.</div>
      </>
    )
  }

  const startDrag = (event: React.PointerEvent, index: number) => {
    event.preventDefault()
    ;(event.target as HTMLElement).setPointerCapture(event.pointerId)
    setDrag({ from: index, over: index })
  }

  const moveDrag = (event: React.PointerEvent) => {
    if (!drag || !listRef.current) return
    const element = document.elementFromPoint(event.clientX, event.clientY)?.closest('[data-queue-index]') as HTMLElement | null
    const over = element ? Number(element.dataset.queueIndex) : drag.over
    // Only upcoming entries can move (as in the Mac app).
    if (Number.isFinite(over) && over > queue.currentIndex && over !== drag.over) setDrag({ ...drag, over })
  }

  const endDrag = () => {
    if (!drag) return
    if (drag.over !== drag.from) send({ type: 'queue-move', target: target(queue, drag.from), toIndex: drag.over })
    setDrag(null)
  }

  const upcomingCount = queue.total - queue.currentIndex - 1

  return (
    <>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 className="page-title">Queue</h1>
        <button
          type="button"
          className="icon-button"
          aria-label="Clear queue"
          onClick={() => useSheet.getState().open({
            title: 'Clear the queue?',
            subtitle: 'Playback stops and every track is removed from the queue.',
            actions: [{ label: 'Clear queue', icon: ListX, run: () => send({ type: 'queue-clear' }) }],
          })}
        >
          <ListX size={22} />
        </button>
      </div>
      <p className="row-sub" style={{ marginTop: -8, marginBottom: 8 }}>
        {upcomingCount > 0 ? `${upcomingCount} up next` : 'Nothing after this track'}
        {queue.shuffle ? ', shuffled' : ''}
      </p>
      <div ref={listRef} onPointerMove={moveDrag} onPointerUp={endDrag} onPointerCancel={() => setDrag(null)}>
        {queue.items.map((track, i) => {
          const index = queue.offset + i
          return (
            <QueueRow
              key={`${index}:${track.key}`}
              queue={queue}
              track={track}
              index={index}
              current={index === queue.currentIndex}
              past={index < queue.currentIndex}
              canDrag={queue.canReorder && index > queue.currentIndex}
              dragging={drag?.over === index}
              onDragStart={startDrag}
            />
          )
        })}
      </div>
      {queue.offset + queue.items.length < queue.total && (
        <p className="row-sub" style={{ padding: '14px 0', textAlign: 'center' }}>
          {queue.total - queue.offset - queue.items.length} more tracks after these
        </p>
      )}
    </>
  )
}
