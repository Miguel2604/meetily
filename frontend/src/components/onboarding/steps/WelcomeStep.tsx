import React from 'react';
import { Lock, Sparkles, Cpu } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { OnboardingContainer } from '../OnboardingContainer';
import { useOnboarding } from '@/contexts/OnboardingContext';
import { MeetyMark } from '@/components/MeetyMark';

export function WelcomeStep() {
  const { goNext } = useOnboarding();

  const features = [
    {
      icon: Lock,
      title: 'Your data never leaves your device',
    },
    {
      icon: Sparkles,
      title: 'Notes and action items written for you',
    },
    {
      icon: Cpu,
      title: 'Works offline, no cloud required',
    },
  ];

  return (
    <OnboardingContainer
      title="Welcome to Meety"
      description="Record. Transcribe. Summarize. All on your device."
      step={1}
      hideProgress={true}
    >
      <div className="flex flex-col items-center space-y-8">
        <MeetyMark size={56} />

        <ul className="w-full max-w-md bg-white rounded-lg border border-gray-200 px-6 py-5 space-y-3.5">
          {features.map((feature) => {
            const Icon = feature.icon;
            return (
              <li key={feature.title} className="flex items-center gap-3 text-[15px] text-gray-900">
                <Icon className="w-4 h-4 text-gray-600 flex-shrink-0" strokeWidth={1.75} />
                {feature.title}
              </li>
            );
          })}
        </ul>

        {/* CTA Section */}
        <div className="w-full max-w-xs space-y-3">
          <Button
            onClick={goNext}
            className="w-full h-11 bg-gray-950 hover:bg-gray-800 text-white"
          >
            Get Started
          </Button>
          <p className="text-sm text-center text-gray-600">Takes less than 3 minutes</p>
        </div>
      </div>
    </OnboardingContainer>
  );
}
