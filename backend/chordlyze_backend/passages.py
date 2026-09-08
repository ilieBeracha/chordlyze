"""Personal passage proposals on the existing leased song worker. Never auto-apply."""
import json
import hashlib
import time
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field
from .auth import current_user
from .song_jobs import SongJobs, library_lock, generation, write_json
from .analysis.engine import validated_segments
from .analysis.review import ChordReview, matching_review
from . import corrections

PASSAGE_REVISION = 'ismir2019-context4-penalty10-v1'


def job_key(user, track):
    return 'passage-' + hashlib.sha256((user+'\0'+track).encode()).hexdigest()


def splice(current, original, proposal, start, end):
    """Preserve every manually edited interval, and everything outside the range."""
    protected = [s for s in current if not any(s == b for b in original)]
    result = []
    for segment in current:
        if segment['end'] <= start or segment['start'] >= end or segment in protected:
            result.append(dict(segment)); continue
        if segment['start'] < start:
            result.append({**segment, 'end': start})
        lo, hi = max(start, segment['start']), min(end, segment['end'])
        for candidate in proposal:
            a, b = max(lo, candidate['start']), min(hi, candidate['end'])
            if b > a:
                result.append({'start': a, 'end': b, 'label': candidate['label']})
        if segment['end'] > end:
            result.append({**segment, 'start': end})
    return result, sum(s['start'] < end and s['end'] > start for s in protected)


def proposal_review(job, proposed, current, original):
    protected = [s for s in current if s not in original]
    return [{**cue, 'start': s['start'], 'end': s['end']}
            for s in proposed if s not in protected
            for cue in job.get('chord_review', [])
            if cue['label'] == s['label'] and cue['start'] <= s['start'] and cue['end'] >= s['end']]


class PassageRequest(BaseModel):
    start: float = Field(ge=0, allow_inf_nan=False)
    end: float = Field(gt=0, allow_inf_nan=False)
    chart_revision: str = Field(pattern=r'^[a-f0-9]{64}$')


class PassageApply(BaseModel):
    id: str = Field(pattern=r'^[a-f0-9]{32}$')
    chart_revision: str = Field(pattern=r'^[a-f0-9]{64}$')


class PassageSegment(BaseModel):
    start: float = Field(ge=0, allow_inf_nan=False)
    end: float = Field(gt=0, allow_inf_nan=False)
    label: str = Field(max_length=40)


class PassageResult(BaseModel):
    track_id: str
    job_id: str
    lease: str
    library_generation: str
    audio_sha256: str = Field(pattern=r'^[a-f0-9]{64}$')
    segments: list[PassageSegment] = Field(min_length=1, max_length=2000)
    chord_review: list[ChordReview] = Field(default_factory=list, max_length=2000)


def router(cache, editable, song_status, worker_auth):
    routes = APIRouter()

    def public(job, user, track):
        if not job or job['generation'] != generation(cache()):
            return None
        result = SongJobs(cache()).public(job) | {k: job.get(k) for k in ('id', 'start', 'end', 'chart_revision', 'applied')}
        if job.get('applied'):
            return result | {'state': 'applied', 'message': 'Passage applied.'}
        if job['state'] in ('queued', 'processing') and not (job.get('message') or '').startswith('Waiting for the recording service'):
            result['message'] = ('Waiting for the analysis worker.' if not result['worker_online']
                                 else 'Checking the matching recording…' if result.get('stage') == 'downloading'
                                 else 'Reanalyzing the passage…' if result.get('stage') == 'analyzing'
                                 else 'Waiting in the analysis queue.')
        try:
            _, chart, _, current = editable(track, user, job['chart_revision'])
        except HTTPException:
            return result | {'state': 'stale', 'message': 'The chart changed. Select the passage again.'}
        if job['state'] == 'ready':
            proposed, protected = splice(corrections.raw(current['chords']), corrections.raw(chart['chords']),
                                         job['segments'], job['start'], job['end'])
            result.update(segments=[s for s in proposed if s['start'] < job['end'] and s['end'] > job['start']],
                          protected_count=protected, chord_review=job.get('chord_review', []))
        return result

    @routes.get('/library/{track}/passage-analysis')
    def existing(track: str, user: str = Depends(current_user)):
        with library_lock(cache()):
            return {'job': public(SongJobs(cache()).get(job_key(user, track)), user, track)}

    @routes.post('/library/{track}/passage-analysis')
    def request(track: str, body: PassageRequest, user: str = Depends(current_user)):
        with library_lock(cache()):
            _, chart, _, current = editable(track, user, body.chart_revision)
            duration = chart.get('audio_duration', 0)
            if not 2 <= body.end-body.start <= 30 or body.end > duration or not chart.get('audio_sha256'):
                raise HTTPException(422, 'Choose a 2–30 second passage within this analyzed recording.')
            # Do not create sound where the original chart has an unanalyzed gap.
            covered = sum(max(0, min(s['end'], body.end)-max(s['start'], body.start)) for s in current['chords'])
            if abs(covered-(body.end-body.start)) > 1e-5:
                raise HTTPException(422, 'This passage contains an unanalyzed gap.')
            jobs = SongJobs(cache()); key = job_key(user, track); previous = jobs.get(key)
            if previous and previous['generation'] == generation(cache()) and previous['state'] in ('queued', 'processing'):
                if (previous['start'], previous['end'], previous['chart_revision']) != (body.start, body.end, body.chart_revision):
                    raise HTTPException(409, 'A passage is already being analyzed for this song. Reopen to follow it.')
                return {'job': public(previous, user, track)}
            pending = [j for p in cache().glob('job-*.json') if (j := json.loads(p.read_text())).get('kind') == 'passage' and j['state'] in ('queued', 'processing')]
            if len(pending) >= 12 or sum(j.get('owner') == hashlib.sha256(user.encode()).hexdigest() for j in pending) >= 3:
                raise HTTPException(429, 'Passage analysis is busy. Wait for a preparation to finish.')
            song = {'track_id': key, 'title': chart.get('title') or track, 'artist': chart.get('artist', ''),
                    'duration': duration, 'isrc': chart.get('isrc'), 'album': chart.get('album')}
            job = jobs.request(song, kind='passage')
            job.update(start=body.start, end=body.end, chart_revision=body.chart_revision,
                       base_revision=corrections.revision(chart), audio_sha256=chart['audio_sha256'],
                       target_track_id=track, owner=hashlib.sha256(user.encode()).hexdigest(),
                       passage_revision=PASSAGE_REVISION, message='Waiting to reanalyze the passage.')
            # Reuse the already selected source when its checkpoint is available.
            original_job = jobs.get(track)
            if original_job and original_job.get('download_checkpoint'):
                job['download_checkpoint'] = original_job['download_checkpoint']
            write_json(jobs.path(key), job)
            return {'job': public(job, user, track)}

    @routes.delete('/library/{track}/passage-analysis/{job_id}')
    def cancel(track: str, job_id: str, user: str = Depends(current_user)):
        with library_lock(cache()):
            jobs = SongJobs(cache()); key = job_key(user, track); job = jobs.get(key)
            if not job or job['id'] != job_id or job['generation'] != generation(cache()):
                raise HTTPException(409, 'This preparation is no longer current.')
            if job['state'] in ('queued', 'processing'):
                job.update(state='cancelled', message='Preparation cancelled. Your chart is unchanged.')
                job.pop('lease', None); write_json(jobs.path(key), job)
            return {'job': public(job, user, track)}

    @routes.post('/internal/jobs/passage')
    def publish(body: PassageResult, authorization: str | None = Header(default=None)):
        worker_auth(authorization)
        with library_lock(cache()):
            jobs = SongJobs(cache()); job = jobs.get(body.track_id)
            if not jobs.valid_lease(body.track_id, body.job_id, body.lease, body.library_generation) or job.get('kind') != 'passage':
                raise HTTPException(409, 'Passage lease is no longer active.')
            if body.audio_sha256 != job['audio_sha256']:
                raise HTTPException(409, 'The recording changed; this proposal cannot be used.')
            try:
                if any(s.start < job['start'] or s.end > job['end'] for s in body.segments):
                    raise ValueError('Proposal extends outside the selected passage.')
                proposed = [s.to_dict() for s in validated_segments([(s.start, s.end, s.label) for s in body.segments], job['end'])]
                if not proposed or abs(proposed[0]['start']-job['start']) > 1e-6 or abs(proposed[-1]['end']-job['end']) > 1e-6:
                    raise ValueError('Proposal must cover the selected passage exactly.')
                if any(abs(a['end']-b['start']) > 1e-6 for a,b in zip(proposed, proposed[1:])):
                    raise ValueError('Proposal contains a gap.')
                review = matching_review([r.model_dump() for r in body.chord_review], proposed)
            except ValueError as error:
                raise HTTPException(422, str(error))
            job.update(state='ready', stage='ready', segments=proposed, chord_review=review,
                       finished_at=time.time(), message='Ready to review. Your chart has not changed.')
            job.pop('lease', None); write_json(jobs.path(body.track_id), job)
            return {'ok': True}

    @routes.post('/library/{track}/passage-analysis/apply')
    def apply(track: str, body: PassageApply, user: str = Depends(current_user)):
        with library_lock(cache()):
            jobs = SongJobs(cache()); key = job_key(user, track); job = jobs.get(key)
            if not job or job['id'] != body.id or job['state'] != 'ready' or job['generation'] != generation(cache()):
                raise HTTPException(409, 'This passage result is no longer available.')
            # A response lost after commit can be retried without applying twice.
            if job.get('applied') and body.chart_revision == job['chart_revision']:
                return song_status(track, user=user)
            if body.chart_revision != job['chart_revision']:
                raise HTTPException(409, 'The proposal belongs to an earlier chart.')
            mine, chart, overlay, current = editable(track, user, body.chart_revision)
            if corrections.revision(chart) != job['base_revision'] or chart['audio_sha256'] != job['audio_sha256']:
                raise HTTPException(409, 'The analyzed recording changed.')
            proposed, _ = splice(corrections.raw(current['chords']), corrections.raw(chart['chords']), job['segments'], job['start'], job['end'])
            change = corrections.commit(chart, current, overlay, proposed)
            # Keep old evidence outside the proposal; exact-match filtering removes stale cues.
            change['review'] = matching_review((current.get('chord_review') or []) + proposal_review(job, proposed, corrections.raw(current['chords']), corrections.raw(chart['chords'])), proposed)
            mine.set_corrections(track, change)
            job['applied'] = True; write_json(jobs.path(key), job)
            return song_status(track, user=user)

    return routes
