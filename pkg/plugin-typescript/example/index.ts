export type Greeting = {
  name: string;
};

export function greet(who: Greeting): string {
  return `Hello, ${who.name}`;
}
