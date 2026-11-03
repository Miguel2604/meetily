'use client';

import { useRouter } from 'next/navigation';
import { ChevronRight } from 'lucide-react';
import { useSidebar } from '@/components/Sidebar/SidebarProvider';

const RECENT_LIMIT = 6;

/** Home screen before a recording starts: what Meety will do, and the way back into recent meetings. */
export function HomeIdle() {
  const router = useRouter();
  const { meetings, setCurrentMeeting } = useSidebar();
  const recent = meetings.slice(0, RECENT_LIMIT);

  return (
    <div className="pt-14">
      <h1 className="text-2xl font-semibold tracking-[-0.01em] text-gray-950">Ready to record</h1>
      <p className="mt-2 max-w-[56ch] text-[15px] leading-relaxed text-gray-600">
        Start recording when the call begins. Meety writes the transcript as people talk and turns it into
        notes afterwards. Audio and text stay on this computer.
      </p>

      <section className="mt-12" aria-labelledby="recent-meetings">
        <div className="flex items-baseline justify-between pb-2 border-b border-gray-200">
          <h2 id="recent-meetings" className="text-sm font-medium text-gray-950">Recent meetings</h2>
          <span className="text-sm text-gray-600 tabular-nums">{meetings.length} saved</span>
        </div>
        {recent.length === 0 ? (
          <p className="mt-3 rounded-md border border-dashed border-gray-300 px-4 py-3 text-sm text-gray-600">
            Your first recording will appear here once it is saved.
          </p>
        ) : (
          <ul>
            {recent.map((meeting) => (
              <li key={meeting.id}>
                <button
                  onClick={() => {
                    setCurrentMeeting({ id: meeting.id, title: meeting.title });
                    router.push(`/meeting-details?id=${meeting.id}`);
                  }}
                  className="group w-full flex items-center gap-3 h-11 -mx-2 px-2 rounded-md text-left text-sm text-gray-900 hover:bg-gray-100 transition-colors"
                  style={{ width: 'calc(100% + 1rem)' }}
                >
                  <span className="flex-1 truncate">{meeting.title}</span>
                  <ChevronRight className="w-4 h-4 text-gray-400 group-hover:text-gray-900 transition-colors" />
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
